---
decision: 稍后做
---

# Cost-Per-Service Tracking for Multi-Cluster Infra

> **Status:** Practical Design Document
> **Date:** 2026-05-23
> **Context:** Track container-level resource usage, estimate cost per service per month, and compare budget vs. actual across all clusters.

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Current State](#2-current-state)
3. [Cost Model](#3-cost-model)
4. [Allocation Method](#4-allocation-method)
5. [ClickHouse Schema](#5-clickhouse-schema)
6. [Collection Script](#6-collection-script)
7. [Budget Definition](#7-budget-definition)
8. [Grafana Dashboard](#8-grafana-dashboard)
9. [Rollout Plan](#9-rollout-plan)

---

## 1. Problem Statement

We run infrastructure across three physical nodes (Mac/Orbstack, Aliyun/sim, Office/nuc8) with 20+ containers providing 10+ distinct services. Currently:

1. **No cost visibility** -- we know the machine costs (electricity, cloud bills, hardware depreciation) but don't know how much each service actually costs.
2. **No budget tracking** -- there are no per-service budgets, so a runaway container (memory leak, disk fill) is invisible until it causes an outage.
3. **No trend data** -- resource usage varies over time (e.g., Grafana dashboard spikes during active hours, ClickHouse grows with data retention). Without trend tracking we can't predict next month's spend.
4. **No cost attribution** -- a container using 100 MiB of RAM and one using 4 GiB are treated equally in terms of "cost."

### What We Want

- **Per-service monthly cost estimate**: given hardware depreciation, cloud VM costs, and electricity, how much does each service cost per month?
- **Budget vs. actual**: set a budget for each service, alert when actual exceeds budget.
- **Trend tracking**: track cost month-over-month to detect anomalies.
- **Capacity planning**: estimate the cost impact of adding a new service or moving a service to another cluster.

---

## 2. Current State

### 2.1 Cluster Inventory

| Cluster | Host | Spec | Disk | Monthly Cost Est. | Role |
|---------|------|------|------|-------------------|------|
| Mac/Orbstack | dongqs-mac | Apple Silicon, 16 GiB RAM | 305 GiB SSD (83 GiB used) | ~$62/mo | Super-boss, central observability, databases, proxy |
| Aliyun (sim) | 47.100.71.220 | 2 vCPU, 1.6 GiB RAM | 40 GiB ESSD (17 GiB used) | ~$12/mo | Cluster-boss, ACR mirror, OSS cache |
| Office (nuc8) | 100.98.29.39 | 8 vCPU, 31 GiB RAM | 36 GiB root (13 GiB used) | ~$19/mo | Cluster-boss, GitLab mirror, Nexus cache, proxy-exit |

**Total monthly infrastructure cost estimate: ~$93/mo** (hardware depreciation + cloud VM + electricity).

### 2.2 Service Catalog (Mac/Orbstack)

| Service Container | CPU% (avg) | Memory | Disk Used | Image Size |
|---|---|---|---|---|
| kyb-infra-clickhouse | 4.54% | 671 MiB | 17.8 GB (data) | 941 MB |
| kyb-infra-grafana | 7.20% | 177 MiB | 147 GB (dashboards, plugins, DB) | 1.05 GB |
| kyb-infra-postgresql-17 | 0.00% | 9 MiB | 3.7 GB | 284 MB |
| kyb-infra-postgresql-16 | 0.02% | 8 MiB | 4.4 GB | 281 MB |
| kyb-infra-postgresql-15 | 0.00% | 30 MiB | 3.6 GB | 279 MB |
| kyb-infra-postgresql-14 | 0.06% | 8 MiB | 15 GB | 277 MB |
| kyb-infra-redis | 0.57% | 4 MiB | 213 MB (AOF/RDB) | 43 MB |
| kyb-infra-kafka | 3.83% | 478 MiB | 31.9 GB (logs) | 447 MB |
| kyb-infra-sing-box | 0.04% | 20 MiB | 19 GB (cache/logs) | 75 MB |
| kyb-infra-cc-connect | 2.88% | 269 MiB | 11.5 GB (logs/data) | 411 MB |
| kyb-registry-cache | 0.02% | 6 MiB | 8.4 GB (blobs) | 29 MB |
| kyb-infra-boss | 222.56%* | 949 MiB | 27.2 GB (image layers) | 10.8 GB |
| kyb-infra-boss3 | 0.42% | 313 MiB | 12.7 GB | 10.7 GB |
| kyb-infra-boss-fallback | 0.24% | 340 MiB | 18.7 GB | 10.6 GB |
| kyb-infra-boss-old | 0.19% | 399 MiB | 21.7 GB | 14.6 GB |

> \* kyb-infra-boss's 222% CPU is anomalous (likely a stuck agent process). This should be <5% during idle. Multiple boss containers are legacy from iterative development and should be pruned.

### 2.3 Service Catalog (Aliyun/sim)

| Service Container | CPU% (avg) | Memory | Disk Used |
|---|---|---|---|
| docker-cache | 0.00% | 38 MiB | (on root disk) |

> sim runs only a build cache service currently. The infra-boss on sim was created but may not be actively running. Future services: ACR mirror, OSS cache.

### 2.4 Service Catalog (Office/nuc8)

- **No containers currently running.** The nuc8 is provisioned and accessible but not yet hosting services.
- Planned services: GitLab mirror, Nexus cache, proxy-exit SOCKS5.

---

## 3. Cost Model

### 3.1 Cost Components

Each machine's total monthly cost is the sum of:

| Component | Mac/Orbstack | Aliyun/sim | Office/nuc8 | Notes |
|-----------|-------------|-------------|-------------|-------|
| **Hardware depreciation** | $42 | -- | $14 | Mac Mini ~$1,500 / 36mo; NUC ~$500 / 36mo |
| **Cloud VM** | -- | $12 | -- | Aliyun ECS 2C2G + 40G ESSD |
| **Electricity** | $15 | -- | $5 | Estimated at $0.12/kWh |
| **Network egress** | $5 | -- | -- | Tailscale DERP relay traffic |
| **Total** | **$62/mo** | **$12/mo** | **$19/mo** | |

### 3.2 Derivation Notes

**Mac/Orbstack:**
- Mac Mini M4 base model: ~$1,500 (one-time). 3-year straight-line depreciation: $42/mo.
- Power: 39W idle, 60W load @ 24/7 = ~35 kWh/mo = ~$4.20 at $0.12/kWh. With monitor/idle overhead: ~$15.
- Network: negligible household bandwidth cost, but factor $5 for Tailscale DERP relay bandwidth.
- Total: $62/mo.

**Aliyun (sim):**
- ECS ecs.e-c1m1.large (2C 2G, 40 GiB ESSD PL0): ~$12/mo (pay-as-you-go, China region).
- No separate electricity cost (included in cloud VM).
- Network egress: included in ECS plan at low usage.
- Total: $12/mo.

**Office (nuc8):**
- Intel NUC8i5BEH (purchased ~$500 in 2020, already depreciated). Replacement value ~$500 / 36mo = $14/mo.
- Power: 30W idle, 60W load @ 24/7 = ~32 kWh/mo = ~$3.80. With overhead: ~$5.
- No cloud VM cost (owned hardware).
- Total: $19/mo.

### 3.3 Per-Cluster Total Monthly Cost

| Cluster | Total | Share of Overall |
|---------|-------|------------------|
| Mac/Orbstack | $62/mo | 67% |
| Aliyun/sim | $12/mo | 13% |
| Office/nuc8 | $19/mo | 20% |
| **All** | **$93/mo** | **100%** |

---

## 4. Allocation Method

### 4.1 Allocation Formula

For each container on a machine, its monthly cost is:

```
container_cost = machine_monthly_cost * weight(container) / sum_of_all_weights
```

Where `weight(container)` is a composite of:

```
weight = (cpu_weight * 0.35) + (mem_weight * 0.35) + (disk_weight * 0.20) + (net_weight * 0.10)
```

The weights reflect that **CPU and memory are the most constrained resources** (16 GB RAM shared across all services, while disk is 305 GB and less contended).

### 4.2 Resource Weight Calculation

For each container, each resource dimension is normalized to a 0-1 score relative to the machine's total capacity:

```
cpu_weight   = container_cpu_pct / 100                     (fraction of 1 core)
mem_weight   = container_mem_bytes / machine_total_mem_bytes
disk_weight  = container_disk_used_bytes / machine_total_disk_bytes
net_weight    = container_net_io_bytes / total_net_io_all_containers
```

### 4.3 Example: Mac/Orbstack Allocation

Machine total: 16 GiB RAM, 8+ CPU cores, 305 GiB disk. Monthly cost: $62.

For `kyb-infra-clickhouse`:
- CPU: 4.54% of 1 core = 0.0454 weight
- Mem: 671 MiB / 16 GiB = 0.0410 weight
- Disk: 17.8 GB / 305 GB = 0.0584 weight
- Net: uses ClickHouse HTTP port (8123), moderate traffic

```
weight = (0.0454 * 0.35) + (0.0410 * 0.35) + (0.0584 * 0.20) + (0.01 * 0.10)
       = 0.0159 + 0.0144 + 0.0117 + 0.0010
       = 0.0430
```

If sum of all container weights = 0.85 (the remaining 15% is overhead/idle):
```
clickhouse monthly cost = $62 * 0.0430 / 0.85 = $3.14/mo
```

### 4.4 Overhead Allocation

Machine overhead (Docker engine, kernel, idle cycles not attributable to any container) is distributed proportionally across services. The overhead weight is:

```
overhead_weight = 1.0 - sum(container_weight)
```

This is re-distributed to all containers in proportion to their individual weights:

```
final_cost(container) = machine_cost * (container_weight / (1 - overhead_weight))
```

In the example above, overhead = 15%, so each container's cost is inflated by 1/(1-0.15) = 1.176x.

### 4.5 Simplification for Initial Rollout

For the initial implementation (Phase 1), use a simplified allocation that assigns **equal base cost + resource premium**:

1. **Base cost per container**: machine_monthly_cost / number_of_containers * 0.5 (50% split equally).
2. **Resource premium**: remaining 50% split proportionally by memory usage (single metric, simplest).

This avoids the complexity of multi-dimensional weighting while capturing the biggest cost driver: memory allocation.

---

## 5. ClickHouse Schema

### 5.1 Container Resource Snapshots

```sql
CREATE TABLE infra_cost.container_resources (
  cluster         String,
  host            String,
  container_name  String,
  image           String,
  timestamp       DateTime64(3) DEFAULT now(),
  cpu_pct         Float32,
  mem_bytes       UInt64,
  mem_limit_bytes UInt64,
  mem_pct         Float32,
  disk_used_bytes UInt64,       -- container layer size (docker ps --size)
  net_rx_bytes    UInt64,       -- cumulative network receive
  net_tx_bytes    UInt64,       -- cumulative network transmit
  block_read_bytes  UInt64,     -- cumulative block I/O read
  block_write_bytes UInt64,     -- cumulative block I/O write
  pids            UInt16,       -- number of processes in container
  state           String        -- running, exited, paused
) ENGINE = MergeTree
ORDER BY (cluster, container_name, timestamp)
TTL timestamp + INTERVAL 90 DAY DELETE;
```

### 5.2 Machine Specs (Infrequently Updated)

```sql
CREATE TABLE infra_cost.machine_specs (
  cluster         String,
  host            String,
  timestamp       DateTime DEFAULT now(),
  total_cpu_cores UInt8,
  total_mem_bytes UInt64,
  total_disk_bytes UInt64,
  monthly_cost_usd Decimal(10,2),  -- manually set, updated on cost changes
  depreciation_months UInt16,
  notes          String
) ENGINE = ReplacingMergeTree
ORDER BY (cluster, host);
```

### 5.3 Monthly Cost Summary (Materialized)

```sql
CREATE TABLE infra_cost.monthly_summary (
  year_month      String,           -- '2026-05'
  cluster         String,
  container_name  String,
  service_name    String,           -- human-friendly e.g. 'ClickHouse'
  avg_cpu_pct     Float32,
  avg_mem_bytes   UInt64,
  peak_mem_bytes  UInt64,
  disk_used_bytes UInt64,
  estimated_cost  Decimal(10,2),    -- USD this month for this container
  machine_cost    Decimal(10,2)     -- the container's share of machine cost
) ENGINE = ReplacingMergeTree
ORDER BY (year_month, cluster, container_name);
```

### 5.4 Budget Definition

```sql
CREATE TABLE infra_cost.budgets (
  service_name    String,
  cluster         String,
  monthly_budget  Decimal(10,2),    -- USD per month
  owner           String,           -- who to notify
  alert_threshold_pct UInt8 DEFAULT 80,  -- alert when actual exceeds this % of budget
  effective_from  Date,
  effective_until Date,
  notes           String,
  updated_at      DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree
ORDER BY (service_name, cluster, effective_from);
```

### 5.5 Budget Alerts

```sql
CREATE TABLE infra_cost.budget_alerts (
  timestamp       DateTime DEFAULT now(),
  service_name    String,
  cluster         String,
  year_month      String,
  budget_usd      Decimal(10,2),
  actual_usd      Decimal(10,2),
  pct_of_budget   Float32,
  severity        Enum('warning' = 1, 'critical' = 2),
  acknowledged    Bool DEFAULT false,
  acknowledged_at Nullable(DateTime)
) ENGINE = MergeTree
ORDER BY (timestamp);
```

### 5.6 Seed Machine Specs

```sql
-- Mac/Orbstack
INSERT INTO infra_cost.machine_specs (cluster, host, total_cpu_cores, total_mem_bytes,
    total_disk_bytes, monthly_cost_usd, depreciation_months, notes)
VALUES ('mac-orbstack', 'dongqs-mac', 8, 17179869184, 327491256320, 62.00, 36,
        'Mac Mini M4, 16GB RAM, 305GiB SSD + 8GiB swap');

-- Aliyun sim
INSERT INTO infra_cost.machine_specs (cluster, host, total_cpu_cores, total_mem_bytes,
    total_disk_bytes, monthly_cost_usd, depreciation_months, notes)
VALUES ('aliyun', 'sim', 2, 1717986918, 42949672960, 12.00, 0,
        'Aliyun ECS ecs.e-c1m1.large, 2C2G, 40GiB ESSD PL0');

-- Office nuc8
INSERT INTO infra_cost.machine_specs (cluster, host, total_cpu_cores, total_mem_bytes,
    total_disk_bytes, monthly_cost_usd, depreciation_months, notes)
VALUES ('office', 'nuc8', 8, 33285996544, 38654705664, 19.00, 36,
        'Intel NUC8i5BEH, 32GB RAM, 36GiB root SSD');
```

---

## 6. Collection Script

### 6.1 Container Resource Collector

This script runs as a cron job inside the infra-boss container on each cluster, collecting resource snapshots every 5 minutes and inserting into central ClickHouse.

```bash
#!/bin/bash
# /usr/local/bin/collect-cost-metrics.sh
# Run every 5 minutes via cron in each boss container.
# Collects per-container resource stats and inserts into central ClickHouse.

CK_HOST="100.104.244.99"
CK_PORT="8123"
CLUSTER="${CLUSTER_NAME:-mac-orbstack}"  # set per boss
HOSTNAME="${HOSTNAME:-unknown}"

run_collect() {
  # Get container stats in JSON
  docker stats --no-stream --format '{
    "container_name": "{{.Name}}",
    "cpu_pct": {{.CPUPerc | trimSuffix "%"}},
    "mem_bytes": {{.MemUsage | regexFind "^[0-9]+"}},
    "mem_limit_bytes": {{.MemLimit | regexFind "^[0-9]+"}},
    "mem_pct": {{.MemPerc}},
    "net_rx_bytes": {{.NetIO | regexFind "^[0-9]+"}},
    "net_tx_bytes": {{.NetIO | regexFind "[0-9]+$"}},
    "block_read_bytes": {{.BlockIO | regexFind "^[0-9]+"}},
    "block_write_bytes": {{.BlockIO | regexFind "[0-9]+$"}},
    "pids": {{.PIDs}}
  }' 2>/dev/null | while read line; do
    curl -s -X POST "http://${CK_HOST}:${CK_PORT}" \
      -d "INSERT INTO infra_cost.container_resources FORMAT JSONEachRow
        $(echo "$line" | sed "s/{/{\"cluster\":\"${CLUSTER}\",\"host\":\"${HOSTNAME}\",/")"
  done

  # Also get disk usage per container (docker ps --size)
  docker ps --format '{
    "container_name": "{{.Names}}",
    "size": "{{.Size}}"
  }' 2>/dev/null | while read line; do
    # Parse size like "44.7MB (virtual 941MB)"
    local size=$(echo "$line" | grep -oP '"size":"[^"]+"' | grep -oP '[0-9.]+[A-Z]+')
    # Convert to bytes and update
    # For simplicity, extract the "size" field (first value before "virtual")
    local real_size=$(echo "$line" | grep -oP '"size":"[0-9.]+[A-Z]+' | grep -oP '[0-9.]+[A-Z]+')
    curl -s -X POST "http://${CK_HOST}:${CK_PORT}" \
      -d "ALTER TABLE infra_cost.container_resources
        UPDATE disk_used_bytes = $(to_bytes "$real_size")
        WHERE container_name = '$(echo "$line" | grep -oP '"container_name":"[^"]+"' | cut -d'"' -f4)'
        AND timestamp >= now() - INTERVAL 5 MINUTE"
  done
}

to_bytes() {
  local val=$1
  local num=$(echo "$val" | grep -oP '[0-9.]+')
  local unit=$(echo "$val" | grep -oP '[A-Z]+')
  case "$unit" in
    KB|kB|K) echo "$num * 1024" | bc ;;
    MB|mB|M) echo "$num * 1048576" | bc ;;
    GB|gB|G) echo "$num * 1073741824" | bc ;;
    TB|tB|T) echo "$num * 1099511627776" | bc ;;
    *) echo "$num" ;;
  esac
}

# Run collect every 5 minutes
while true; do
  run_collect
  sleep 300
done
```

### 6.2 Monthly Cost Computation

A monthly cron job (or ClickHouse materialized view) computes per-service costs:

```sql
-- Create materialized view for monthly summary
CREATE MATERIALIZED VIEW infra_cost.monthly_summary_mv
ENGINE = ReplacingMergeTree
ORDER BY (year_month, cluster, container_name)
AS SELECT
  formatDateTime(timestamp, '%Y-%m') AS year_month,
  cluster,
  container_name,
  -- Map container name to service name (simple heuristic for now)
  multiIf(
    container_name LIKE '%clickhouse%', 'ClickHouse',
    container_name LIKE '%grafana%', 'Grafana',
    container_name LIKE '%postgresql%', 'PostgreSQL',
    container_name LIKE '%redis%', 'Redis',
    container_name LIKE '%kafka%', 'Kafka',
    container_name LIKE '%sing-box%', 'Sing-Box',
    container_name LIKE '%cc-connect%', 'CC-Connect',
    container_name LIKE '%registry-cache%', 'Registry Cache',
    container_name LIKE '%boss%', 'Infra Boss',
    'Other'
  ) AS service_name,
  avg(cpu_pct) AS avg_cpu_pct,
  avg(mem_bytes) AS avg_mem_bytes,
  max(mem_bytes) AS peak_mem_bytes,
  argMax(disk_used_bytes, timestamp) AS disk_used_bytes,
  -- Cost: simplified for now, will be refined with machine cost data
  0 AS estimated_cost
FROM infra_cost.container_resources
GROUP BY year_month, cluster, container_name;
```

### 6.3 Cost Calculator Script

A separate script runs at the end of each month (or on-demand) to compute actual costs:

```bash
#!/bin/bash
# /usr/local/bin/compute-monthly-cost.sh
# Computes monthly cost per service using the allocation formula.

CK_HOST="100.104.244.99"
CK_PORT="8123"
YEAR_MONTH="${1:-$(date +%Y-%m)}"

echo "Computing costs for ${YEAR_MONTH}..."

# Get machine specs
MACHINES=$(curl -s "http://${CK_HOST}:${CK_PORT}" \
  -d "SELECT cluster, host, monthly_cost_usd
      FROM infra_cost.machine_specs
      WHERE timestamp = (SELECT max(timestamp) FROM infra_cost.machine_specs)
      FORMAT JSONEachRow")

# For each machine, compute container costs
for machine in $(echo "$MACHINES" | jq -c .); do
  CLUSTER=$(echo "$machine" | jq -r '.cluster')
  MONTHLY_COST=$(echo "$machine" | jq -r '.monthly_cost_usd')
  HOST=$(echo "$machine" | jq -r '.host')

  echo "  Processing ${CLUSTER} (${MONTHLY_COST}/mo)..."

  # Get monthly aggregates for this cluster
  CONTAINERS=$(curl -s "http://${CK_HOST}:${CK_PORT}" \
    -d "SELECT
          container_name,
          avg(mem_pct) AS avg_mem_pct,
          avg(cpu_pct) AS avg_cpu_pct
        FROM infra_cost.container_resources
        WHERE cluster = '${CLUSTER}'
          AND formatDateTime(timestamp, '%Y-%m') = '${YEAR_MONTH}'
          AND state = 'running'
        GROUP BY container_name
        FORMAT JSONEachRow")

  # Simple allocation: 50% equal split + 50% proportional to mem_pct
  TOTAL_CONTAINERS=$(echo "$CONTAINERS" | jq -s 'length')
  TOTAL_MEM=$(echo "$CONTAINERS" | jq -s '[.[].avg_mem_pct] | add')

  BASE_SHARE=$(echo "$MONTHLY_COST * 0.5 / $TOTAL_CONTAINERS" | bc -l)
  MEM_UNIT_COST=$(echo "scale=10; $MONTHLY_COST * 0.5 / $TOTAL_MEM" | bc -l 2>/dev/null || echo 0)

  echo "$CONTAINERS" | jq -c . | while read container; do
    NAME=$(echo "$container" | jq -r '.container_name')
    MEM_PCT=$(echo "$container" | jq -r '.avg_mem_pct // 0')
    MEM_SHARE=$(echo "$MEM_PCT * $MEM_UNIT_COST" | bc -l 2>/dev/null || echo 0)
    TOTAL=$(echo "$BASE_SHARE + $MEM_SHARE" | bc -l)
    TOTAL_ROUNDED=$(printf "%.2f" "$TOTAL")

    curl -s -X POST "http://${CK_HOST}:${CK_PORT}" \
      -d "INSERT INTO infra_cost.monthly_summary FORMAT JSONEachRow {
        \"year_month\": \"${YEAR_MONTH}\",
        \"cluster\": \"${CLUSTER}\",
        \"container_name\": \"${NAME}\",
        \"estimated_cost\": ${TOTAL_ROUNDED},
        \"machine_cost\": ${MONTHLY_COST}
      }"
  done
done

echo "Done computing costs for ${YEAR_MONTH}."
```

> **Note on the simplified allocation**: 50% equal split + 50% memory-proportional is chosen for initial rollout because:
> - Memory is the most constrained resource on Mac/Orbstack (16 GiB shared across services)
> - It avoids requiring accurate CPU measurement (docker stats CPU% is instantaneous, not truly averaged)
> - It is easy to explain and audit: each container gets a base cost for existing + a memory premium
> - The formula can be refined later when we have historical data to calibrate

---

## 7. Budget Definition

### 7.1 Default Budgets

Initial budgets based on expected resource usage and service criticality:

| Service | Cluster | Monthly Budget | Justification |
|---------|---------|---------------|---------------|
| ClickHouse | mac-orbstack | $6.00 | Central observability, 671 MiB RAM, growing disk |
| Grafana | mac-orbstack | $4.00 | Dashboards, 177 MiB RAM, 147 GB of dashboards/plugins |
| PostgreSQL (4 instances) | mac-orbstack | $8.00 | PG 14/15/16/17 fleet, ~55 MiB total RAM, ~27 GiB total disk |
| Redis | mac-orbstack | $1.00 | Lightweight cache, 4 MiB RAM, minimal disk |
| Kafka | mac-orbstack | $6.00 | Message broker, 478 MiB RAM, 32 GiB disk for logs |
| Sing-Box | mac-orbstack | $3.00 | Proxy exit, 20 MiB RAM, bandwidth-dependent |
| CC-Connect | mac-orbstack | $5.00 | Bridge service, 269 MiB RAM, production-critical |
| Registry Cache | mac-orbstack | $2.00 | Docker image cache, minimal RAM, moderate disk |
| Infra Boss (containers) | mac-orbstack | $10.00 | Management plane, multiple boss containers |
| Infra Boss | aliyun | $6.00 | Cluster management on sim |
| Docker Cache | aliyun | $2.00 | Build cache, 38 MiB RAM |
| Machine overhead | all | remainder | Idle cycles, Docker engine overhead |
| **Total** | **all** | **~$55.00** | vs. $93/mo total (remaining is overhead buffer) |

### 7.2 Setting Budgets in ClickHouse

```sql
-- Seed initial budgets
INSERT INTO infra_cost.budgets (service_name, cluster, monthly_budget,
    owner, alert_threshold_pct, effective_from, effective_until, notes)
VALUES
  ('ClickHouse',         'mac-orbstack', 6.00, 'boss', 80, '2026-06-01', '2027-06-01', 'Central observability'),
  ('Grafana',            'mac-orbstack', 4.00, 'boss', 80, '2026-06-01', '2027-06-01', 'Dashboards'),
  ('PostgreSQL',         'mac-orbstack', 8.00, 'boss', 85, '2026-06-01', '2027-06-01', 'PG fleet 14-17'),
  ('Redis',              'mac-orbstack', 1.00, 'boss', 80, '2026-06-01', '2027-06-01', 'Cache'),
  ('Kafka',              'mac-orbstack', 6.00, 'boss', 80, '2026-06-01', '2027-06-01', 'Message broker'),
  ('Sing-Box',           'mac-orbstack', 3.00, 'boss', 80, '2026-06-01', '2027-06-01', 'Proxy exit'),
  ('CC-Connect',         'mac-orbstack', 5.00, 'boss', 85, '2026-06-01', '2027-06-01', 'Bridge service'),
  ('Registry Cache',     'mac-orbstack', 2.00, 'boss', 80, '2026-06-01', '2027-06-01', 'Docker image cache'),
  ('Infra Boss',         'mac-orbstack', 10.00, 'boss', 90, '2026-06-01', '2027-06-01', 'Multiple boss containers'),
  ('Infra Boss',         'aliyun',       6.00, 'boss', 80, '2026-06-01', '2027-06-01', 'Cluster management'),
  ('Docker Cache',       'aliyun',       2.00, 'boss', 80, '2026-06-01', '2027-06-01', 'Build cache');
```

### 7.3 Budget Alert Rules

| Severity | Condition | Action |
|----------|----------|--------|
| **Warning** | Actual > 80% of budget for 2 consecutive days | Notify boss via feishu, log to `budget_alerts` |
| **Critical** | Actual > 100% of budget for 1 day | Notify boss urgently, trigger incident |
| **Warning** | 3-month trend shows budget will be exceeded next month | Flag for budget review |

Budget alert query:

```sql
-- Budget alert check (run daily)
SELECT
  b.service_name,
  b.cluster,
  b.monthly_budget,
  COALESCE(SUM(m.estimated_cost), 0) AS actual_so_far,
  formatDateTime(now(), '%Y-%m') AS current_month,
  (COALESCE(SUM(m.estimated_cost), 0) / b.monthly_budget) * 100 AS pct_used
FROM infra_cost.budgets b
LEFT JOIN infra_cost.monthly_summary m
  ON m.service_name = b.service_name
  AND m.cluster = b.cluster
  AND m.year_month = formatDateTime(now(), '%Y-%m')
WHERE now() BETWEEN b.effective_from AND b.effective_until
GROUP BY b.service_name, b.cluster, b.monthly_budget
HAVING pct_used > b.alert_threshold_pct
ORDER BY pct_used DESC;
```

---

## 8. Grafana Dashboard

### 8.1 Dashboard: "Infra Cost Per Service"

Panels:

1. **Monthly Cost Overview** (bar chart)
   - X: service name, Y: estimated cost ($)
   - Color by cluster
   - Show budget line overlay per service

2. **Budget vs. Actual** (gauge panel per service)
   - Green < 80%, Yellow 80-99%, Red >= 100%
   - Show current month's actual spend as % of budget

3. **Cost Trend** (time series)
   - X: month, Y: cost ($)
   - One series per service
   - 6-month rolling window
   - Budget line as dashed horizontal

4. **Cluster Cost Breakdown** (pie chart)
   - Slice per cluster: Mac/Orbstack, Aliyun, Office
   - Show absolute cost and percentage

5. **Resource Allocation Table** (table panel)
   - Columns: Service, Cluster, CPU%, Memory, Disk, Cost, Budget, % of Budget
   - Sortable, searchable

6. **Top 5 Most Expensive Containers** (horizontal bar chart)
   - Highlight anomalies (e.g., boss containers using 222% CPU)

7. **Cost Anomaly Feed** (log panel)
   - Entries from `budget_alerts` table
   - Show recent warnings and criticals

8. **Machine Utilization** (stat panels per cluster)
   - Total cost, total containers, avg CPU%, avg mem%

### 8.2 Prometheus Queries (Alternative to CK for Real-Time)

If Prometheus is available, we can use these queries instead of CK for real-time panels:

```promql
# Container memory usage %
100 * (container_memory_usage_bytes{name=~"kyb-infra-.*"} / machine_memory_bytes)

# Estimated cost per container (with static machine cost label)
container_memory_usage_bytes{name=~"kyb-infra-.*"}
  * on() group_left() (62.0 / 17179869184)   # $62/mo for 16 GiB Mac
```

For the initial implementation, we will use ClickHouse as the primary datasource (already available) and add Prometheus later if needed.

---

## 9. Rollout Plan

### Phase 1: Manual Baseline (Week 1)

1. Create CK tables (Section 5.1 - 5.5) on central ClickHouse.
2. Manually compute costs based on current `docker stats` snapshot:
   - Run `collect-cost-metrics.sh` once on each boss.
   - Run `compute-monthly-cost.sh` for current month.
3. Validate against actual Docker resource usage.
4. Adjust budgets if needed.

### Phase 2: Automated Collection (Week 1-2)

1. Deploy `collect-cost-metrics.sh` as a cron job in each infra-boss:
   ```bash
   # Inside each boss container, add to crontab:
   crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/collect-cost-metrics.sh" | crontab -
   ```
2. Deploy to all 3 bosses:
   ```bash
   docker cp collect-cost-metrics.sh infra-boss:/usr/local/bin/
   docker exec infra-boss bash -c "echo '*/5 * * * * /usr/local/bin/collect-cost-metrics.sh' | crontab -"
   
   # Aliyun
   ssh sim "docker cp collect-cost-metrics.sh kyb-infra-boss:/usr/local/bin/"
   
   # Office (when services are deployed)
   ssh nuc8 "docker cp collect-cost-metrics.sh kyb-infra-boss:/usr/local/bin/"
   ```
3. Verify data arriving in CK after 15 minutes.
4. Build Grafana dashboard (Section 8).

### Phase 3: Budget Alerts (Week 2-3)

1. Seed budget definitions (Section 7.2).
2. Deploy budget alert check as a cron job on the super-boss:
   ```bash
   # Check budgets every 6 hours
   0 */6 * * * /usr/local/bin/check-budgets.sh
   ```
3. Add feishu notification for budget breaches.
4. Tune alert thresholds based on first week of data.

### Phase 4: Refine & Extend (Week 3+)

1. Add network cost tracking (egress bandwidth costs for sing-box proxy).
2. Add storage cost tracking for Docker volumes (not just container layers).
3. Push cost data into Grafana as an annotation source (show "budget exceeded" on dashboards).
4. Add cost forecasting: linear regression on 3-month trend to predict next month.
5. Automate budget review: monthly summary sent to feishu.

### Quick-Start Commands

```bash
# 1. Create CK tables (run from super-boss or CK host)
cat docs/infra/reviews/cost-per-service.md | grep -A200 'CREATE TABLE' | grep -B1 -A30 'ENGINE =' | while read line; do
  curl -s -X POST http://localhost:8123 -d "$line" --data-binary @-
done

# 2. Run initial snapshot
docker exec infra-boss bash -c "
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'
" > /tmp/initial-cost-baseline.txt

# 3. View results
cat /tmp/initial-cost-baseline.txt
```

---

## Appendix: Initial Cost Estimate (from current snapshot)

Using the simplified 50/50 allocation formula on current Mac/Orbstack containers:

| Service | Avg Mem | Mem Share | Base Share | Est. Cost/Mo | Budget | Delta |
|---------|---------|-----------|------------|-------------|--------|-------|
| ClickHouse | 671 MiB | $2.04 | $2.58 | $4.62 | $6.00 | -$1.38 |
| Grafana | 177 MiB | $0.54 | $2.58 | $3.12 | $4.00 | -$0.88 |
| PostgreSQL-17 | 9 MiB | $0.03 | $2.58 | $2.61 | $2.00* | +$0.61 |
| PostgreSQL-16 | 8 MiB | $0.02 | $2.58 | $2.60 | $2.00* | +$0.60 |
| PostgreSQL-15 | 30 MiB | $0.09 | $2.58 | $2.67 | $2.00* | +$0.67 |
| PostgreSQL-14 | 8 MiB | $0.02 | $2.58 | $2.60 | $2.00* | +$0.60 |
| Redis | 4 MiB | $0.01 | $2.58 | $2.59 | $1.00 | +$1.59 |
| Kafka | 478 MiB | $1.45 | $2.58 | $4.03 | $6.00 | -$1.97 |
| Sing-Box | 20 MiB | $0.06 | $2.58 | $2.64 | $3.00 | -$0.36 |
| CC-Connect | 269 MiB | $0.82 | $2.58 | $3.40 | $5.00 | -$1.60 |
| Registry Cache | 6 MiB | $0.02 | $2.58 | $2.60 | $2.00 | +$0.60 |
| Infra Boss (4 cntrs) | ~2000 MiB | $6.08 | $10.32 | $16.40 | $10.00 | +$6.40 |

> \* PostgreSQL budget is $8.00 total for 4 instances = $2.00 each average.
> **Infra Boss** is over budget because there are 4 boss containers running simultaneously. Reducing to 1 boss container would bring this down to ~$5.00/mo.

**Key insights from initial estimate:**
1. **Boss container sprawl** is the #1 cost overrun: 4 boss containers consume ~$16.40/mo (26% of cluster cost). Pruning to 1 active boss saves ~$11/mo.
2. **Redis** appears over-budget because the base (equal) share is too high for a 4 MiB service. After Phase 1 data collection, the allocation formula should be tuned or Redis should get an adjusted base share.
3. **ClickHouse, Grafana, Kafka, CC-Connect** are all under budget -- the simplified allocation undercounts services that do significant disk I/O (ClickHouse writes 17+ GB, Kafka writes 32+ GB).
4. **Total allocated**: $52.28 of $62.00/mo (84%). The remaining $9.72 is overhead/idle, which is reasonable.

### Next Data Point: Budget Adjustment Rules

After 3 months of data:
- If a service is consistently <50% of budget for 2+ months, reduce its budget by 20%.
- If a service is consistently >90% of budget for 2+ months, increase its budget by 20% and investigate.
- If a single container uses more than 30% of a cluster's total cost, flag for right-sizing review.

---

> **Summary:** Cost-per-service tracking converts our infrastructure spending from an opaque total into an attributable cost per service. Initial estimates show $52/mo allocated across services on Mac/Orbstack (out of $62/mo total), with boss containers as the top cost driver. Phase 1 collects baseline data, Phase 2 automates collection, Phase 3 adds budget alerts, and Phase 4 refines the model.

> ／人◕ ‿‿ ◕人＼
