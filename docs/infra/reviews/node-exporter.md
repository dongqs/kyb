---
decision: 稍后做
---

# Node Exporter: Host-Level Metrics for Orbstack VM

**Author:** Boss
**Date:** 2026-05-23
**Scope:** Design for deploying node_exporter to collect CPU, memory, disk, network, and load metrics from the Orbstack VM host, ingested into the existing Prometheus/Grafana stack.
**Status:** Draft

---

## 1. Motivation

The current observability stack (OTel Collector -> Prometheus -> Grafana) captures application-level metrics from containers (cc-connect, Vector, etc.) but has no visibility into the **host** — the Orbstack VM that runs every container.

Without host metrics:

- A CPU spike could be a noisy-neighbor container or host CPU pressure — indistinguishable.
- Disk fill-up is detected only when a container fails to write — by then it's an incident, not an alert.
- OOM kills go unnoticed until a container disappears.
- Network bandwidth contention is invisible.

Adding node_exporter fills this gap: Prometheus scrapes `node_exporter:9100` alongside OTel collector metrics, giving a single pane of glass for host + container health.

## 2. Architecture

```
Orbstack VM (Docker Host)
│
├── node_exporter (container)
│   └── port 9100
│   └── mounts: /proc:/host/proc, /sys:/host/sys, /:/host/root
│
├── prometheus (container) ─── scrape http://node_exporter:9100/metrics
│
└── grafana (container) ─── dashboard: "Orbstack Host"
```

### 2.1 Deployment

node_exporter runs as a Docker container on the Orbstack VM, not on the macOS host. This is deliberate:

| Approach | Pros | Cons |
|----------|------|------|
| **Container on Orbstack VM** | Same Docker network as Prometheus; no macOS firewall port exposure; managed via `docker-compose` alongside other infra containers | Metrics are from the Orbstack VM, not the macOS host (acceptable — containers only care about VM resources) |
| **macOS native binary** | Real host metrics (macOS CPU/memory/battery) | Different network namespace; separate lifecycle management; no macOS Prometheus exporter ecosystem |

For kyb infrastructure, the Orbstack VM _is_ the host — containers don't see macOS. The VM's resource pressure directly impacts container performance, so VM-level metrics are sufficient.

### 2.2 Docker Compose Addition

```yaml
services:
  node_exporter:
    image: prom/node-exporter:v1.8.2
    container_name: node_exporter
    restart: unless-stopped
    network_mode: host  # or bridge with port mapping
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/host/root:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/host/root'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
```

### 2.3 Prometheus Scrape Config

Append to `prometheus.yml` scrape configs:

```yaml
scrape_configs:
  - job_name: 'node'
    static_configs:
      - targets: ['node_exporter:9100']
    scrape_interval: 15s
    scrape_timeout: 10s
    # Keep the hostname label to identify which host in multi-cluster setups
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: 'orbstack-vm'
```

If node_exporter uses `network_mode: host`, the target becomes `localhost:9100` from Prometheus's perspective (same Docker network namespace as the host). If using bridge mode, use the container name `node_exporter:9100`.

## 3. Key Metrics

### 3.1 CPU

| Metric | Type | What It Tells Us |
|--------|------|------------------|
| `node_cpu_seconds_total{mode="idle"}` | counter | Idle time → 1 minus this is CPU utilization |
| `node_cpu_seconds_total{mode="user"}` | counter | User-space CPU usage |
| `node_cpu_seconds_total{mode="system"}` | counter | Kernel CPU usage |
| `node_cpu_seconds_total{mode="iowait"}` | counter | Waiting for I/O — high means disk bottleneck |
| `node_load1` / `node_load5` / `node_load15` | gauge | System load averages |

**Typical queries:**

```
# CPU utilization (excluding idle)
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# CPU iowait ratio
avg by (instance) (rate(node_cpu_seconds_total{mode="iowait"}[5m])) * 100

# Load average vs CPU count
node_load15 / count(node_cpu_seconds_total{mode="idle"})
```

### 3.2 Memory

| Metric | Type | What It Tells Us |
|--------|------|------------------|
| `node_memory_MemTotal_bytes` | gauge | Total physical RAM |
| `node_memory_MemAvailable_bytes` | gauge | Available RAM (accurate for modern Linux, includes reclaimable) |
| `node_memory_MemFree_bytes` | gauge | Completely free RAM |
| `node_memory_Buffers_bytes` | gauge | Buffer cache |
| `node_memory_Cached_bytes` | gauge | Page cache + tmpfs |
| `node_memory_SwapTotal_bytes` / `node_memory_SwapFree_bytes` | gauge | Swap usage |

**Typical queries:**

```
# Memory utilization
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Swap usage
(node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes) / node_memory_SwapTotal_bytes * 100
```

**Alert threshold:** MemAvailable < 10% of MemTotal for > 5 minutes.

### 3.3 Disk

| Metric | Type | What It Tells Us |
|--------|------|------------------|
| `node_filesystem_size_bytes{mountpoint="/"}` | gauge | Total disk per mount |
| `node_filesystem_free_bytes{mountpoint="/"}` | gauge | Free disk per mount |
| `node_filesystem_avail_bytes{mountpoint="/"}` | gauge | Available to non-root users |
| `node_disk_io_time_seconds_total{device="..."}` | counter | I/O time — high → disk saturation |
| `node_disk_read_bytes_total{device="..."}` | counter | Bytes read |
| `node_disk_written_bytes_total{device="..."}` | counter | Bytes written |

**Mountpoint filter:** Orbstack VM mounts include the macOS host filesystem via `/host/root`. Filter to relevant mounts:

```
# VM root filesystem (ext4 on Orbstack VM)
node_filesystem_avail_bytes{mountpoint="/", fstype!="tmpfs"}

# Docker data directory (if separate volume)
node_filesystem_avail_bytes{mountpoint="/var/lib/docker"}
```

**Typical queries:**

```
# Disk usage per mount
(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100

# Disk I/O utilization (as fraction of time busy)
rate(node_disk_io_time_seconds_total[5m])
```

**Alert threshold:** Disk usage > 85% for root, > 80% for /var/lib/docker.

### 3.4 Network

| Metric | Type | What It Tells Us |
|--------|------|------------------|
| `node_network_receive_bytes_total{device="eth0"}` | counter | Inbound bytes |
| `node_network_transmit_bytes_total{device="eth0"}` | counter | Outbound bytes |
| `node_network_receive_errors_total{device="eth0"}` | counter | Receive errors (usually indicates link issues) |
| `node_network_transmit_errors_total{device="eth0"}` | counter | Transmit errors |
| `node_network_receive_drop_total{device="eth0"}` | counter | Dropped packets (buffer full → backpressure) |

**Device filter:** Exclude virtual interfaces (veth*, docker*, br-*). Focus on the Orbstack VM's physical/primary interface (typically `eth0` inside the VM).

**Typical queries:**

```
# Network throughput (bits/sec)
rate(node_network_receive_bytes_total{device="eth0"}[5m]) * 8
rate(node_network_transmit_bytes_total{device="eth0"}[5m]) * 8

# Error rate
rate(node_network_receive_errors_total{device="eth0"}[5m])
```

### 3.5 System / Load

| Metric | Type | What It Tells Us |
|--------|------|------------------|
| `node_load1` | gauge | 1-minute load average |
| `node_load5` | gauge | 5-minute load average |
| `node_load15` | gauge | 15-minute load average |
| `node_nf_conntrack_entries` | gauge | Connection tracking table usage |
| `node_context_switches_total` | counter | Context switch rate (high → scheduler pressure) |
| `node_procs_running` | gauge | Processes in run queue (not sleeping) |
| `node_procs_blocked` | gauge | Processes blocked on I/O |
| `node_time_seconds` | gauge | System time (for NTP drift alerting) |
| `node_boot_time_seconds` | gauge | Boot time (for uptime tracking) |

**Typical queries:**

```
# Load / CPU core ratio
node_load15 / count(node_cpu_seconds_total{mode="idle"})

# Conntrack utilization
node_nf_conntrack_entries / node_nf_conntrack_entries_limit * 100

# Process pressure
node_procs_running  # if sustained > CPU count → overload
```

## 4. Collectors

node_exporter has optional collectors. Enable only what's needed:

```yaml
command:
  - '--collector.cpu'
  - '--collector.diskstats'
  - '--collector.filesystem'
  - '--collector.loadavg'
  - '--collector.meminfo'
  - '--collector.netdev'
  - '--collector.netstat'
  - '--collector.stat'        # context switches, interrupts
  - '--collector.time'
  - '--collector.uptime'
  - '--collector.conntrack'
  # Disable noisy or irrelevant collectors:
  - '--no-collector.arp'
  - '--no-collector.bcache'
  - '--no-collector.dmi'
  - '--no-collector.edac'
  - '--no-collector.entropy'
  - '--no-collector.infiniband'
  - '--no-collector.pressure'  # Linux psi — Orbstack VM kernel may not support
  - '--no-collector.schedstat'
  - '--no-collector.softnet'
  - '--no-collector.thermal_zone'
  - '--no-collector.wifi'
```

This keeps metric cardinality manageable (~300 time series vs ~1200 with all collectors enabled).

## 5. Grafana Dashboard

Create a dashboard titled **"Orbstack Host"** with the following panels:

### Row 1: CPU
- CPU Utilization (%) — time series (idle-calculated)
- Load Average — time series (1/5/15 min overlayed)
- CPU IOWait (%) — time series
- Context switches — rate per second

### Row 2: Memory
- Memory Usage (%) — gauge or time series
- Memory Breakdown — stacked area (used / buffers / cached / free)
- Swap Usage (%) — gauge

### Row 3: Disk
- Root Disk Usage (%) — gauge
- Disk I/O — read/write bytes/s — time series
- Disk I/O Utilization (%) — time series (busy fraction)

### Row 4: Network
- Network Throughput — bits/s in/out — time series
- Network Errors — time series (if non-zero, alert)

### Row 5: System Health
- Uptime — stat
- Running Processes — stat
- Conntrack Usage (%) — gauge

### Provisioning

Dashboard JSON should be checked into the repo and auto-provisioned to Grafana via the `grafana/dashboards` directory (following the same pattern as other dashboards):

```
grafana/dashboards/orbstack-host.json
```

## 6. Alerts

Alerting rules for Prometheus (or Grafana managed alerts):

```yaml
groups:
  - name: node_exporter
    rules:
      - alert: HostHighCPU
        expr: (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) by (instance)) * 100 > 90
        for: 5m
        annotations:
          summary: "Host CPU > 90% for 5 minutes"

      - alert: HostMemoryLow
        expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.1
        for: 5m
        annotations:
          summary: "Host memory available < 10%"

      - alert: HostDiskFull
        expr: (node_filesystem_avail_bytes{mountpoint="/root"} / node_filesystem_size_bytes{mountpoint="/root"}) < 0.15
        for: 5m
        annotations:
          summary: "Host root disk < 15% free"

      - alert: HostDiskFillRate
        expr: predict_linear(node_filesystem_avail_bytes{mountpoint="/root"}[6h], 3600 * 24) < 0
        for: 10m
        annotations:
          summary: "Host root disk will fill within 24h at current rate"

      - alert: HostNetworkErrors
        expr: rate(node_network_receive_errors_total{device="eth0"}[5m]) > 0
        for: 5m
        annotations:
          summary: "Network errors detected on host interface eth0"

      - alert: HostConntrackHigh
        expr: node_nf_conntrack_entries / node_nf_conntrack_entries_limit > 0.8
        for: 5m
        annotations:
          summary: "Connection tracking table > 80% full"
```

## 7. Integration with Existing Stack

The existing infra stack (per `multi-cluster-boss-architecture.md`) already runs Prometheus and Grafana on the Orbstack VM. Deploying node_exporter:

1. Add the `node_exporter` service to the existing `docker-compose.yml` that manages infra containers.
2. Add the scrape target to Prometheus config.
3. Import the Grafana dashboard (version-controlled).
4. Add alerting rules to the existing alertmanager config.

No new infrastructure. No new ports exposed to the internet. Node exporter is reachable only within the Orbstack Docker network.

### Current Stack Compatibility

| Component | Status | Action |
|-----------|--------|--------|
| Prometheus | Already running, scraping OTel metrics | Add node_exporter target |
| Grafana | Already running with dashboards | Import "Orbstack Host" dashboard |
| Alertmanager | Already configured | Add node_exporter alert rules |
| OTel Collector | Unchanged | No OTel involvement — node_exporter speaks native Prometheus |

## 8. Non-Goals

- **macOS host metrics** (battery, thermal, App memory pressure): The Orbstack VM does not expose these. Use `macchina` / `htop` on macOS directly if needed.
- **Container-level metrics**: Already handled by cAdvisor or OTel SDK metrics. node_exporter is for the host, not per-container.
- **GPU metrics**: Orbstack VM does not expose GPU.
- **Custom exporters**: Start with node_exporter only. If specific needs arise (e.g., Docker daemon metrics via `--collector.docker`), add later as a separate review.

## 9. Future Considerations

- **Per-cluster host labels**: If a second host is added (multi-cluster per `multi-cluster-boss-architecture.md`), add a `cluster` label to the Prometheus target and replicate the dashboard per cluster.
- **Node exporter on NAS**: If a Synology/NAS is added for storage, run node_exporter there too (Docker package on DSM supports it).
- **Unified host dashboard**: Once multiple hosts exist, create a meta-dashboard with per-host rows selected by `cluster` variable.
