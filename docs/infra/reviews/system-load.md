---
decision: 稍后做
---

# System Load Average Monitoring

**Author:** Boss
**Date:** 2026-05-23
**Scope:** Design for monitoring host system load from multiple angles — CPU run queue depth, context switch rate, disk IO pressure, and saturation signals — building on node_exporter metrics with focused alerting and a dedicated Grafana panel row.
**Status:** Draft

---

## 1. Motivation

The standard "CPU utilization" graph (100 minus idle) tells us the host is busy, but not *how* it is busy. Two hosts can both show 80% CPU with wildly different user experience:

| Scenario | CPU% | Load15 | Context Switches | IO Wait | Run Queue |
|----------|------|--------|------------------|---------|-----------|
| Compute-bound (compilation) | 80% | 4.0 | 10k/s | 0.5% | 4 running |
| IO-bound (disk saturation) | 80% | 12.0 | 100k/s | 35% | 2 running, 10 blocked |

The second host is neck-deep in pressure — processes pile up in the run queue, the scheduler thrashes, and disk IO completes slowly. A plain CPU% graph cannot distinguish these states.

Load average monitoring fills this gap by tracking **saturation**, not just utilization:

- **Run queue depth** (`node_procs_running`) — how many processes are contending for CPU right now.
- **Context switch rate** (`node_context_switches_total`) — how hard the scheduler is working; high context switch rate with low CPU% suggests lock contention or IO completions.
- **Blocked processes** (`node_procs_blocked`) — processes waiting for IO to complete; sustained non-zero values indicate IO pressure.
- **Pressure Stall Information (PSI)** — Linux kernel's direct measurement of time tasks spend waiting for CPU, IO, or memory.

## 2. Architecture

No new components. All metrics are already available from node_exporter (per `node-exporter.md`). This review covers **configuration, alerting, and dashboard design** to surface load signals.

```
node_exporter (already deployed)
│
├── /proc/stat          → context_switches_total, procs_running, procs_blocked
├── /proc/pressure/     → cpu, io, memory pressure (PSI)
├── /proc/loadavg       → load1, load5, load15
└── /proc/diskstats     → disk IO time, weighted IO time
    │
    └── Prometheus scrape interval: 15s
         │
         └── Grafana dashboard: "Orbstack Host" → Load row
         └── Alertmanager: load saturation rules
```

### 2.1 Prerequisites

node_exporter must be running with the following collectors enabled (check `node-exporter.md` for the base config):

```yaml
# Required collectors for load monitoring (add if not present)
command:
  - '--collector.stat'        # context_switches_total, procs_running, procs_blocked
  - '--collector.loadavg'     # load1, load5, load15
  - '--collector.diskstats'   # disk IO time, weighted IO time
  - '--collector.pressure'    # PSI metrics (Linux 4.20+, most kernels support it)
```

If `--collector.pressure` is disabled because the Orbstack VM kernel lacks PSI support, all other signals still work. PSI is a nice-to-have, not a requirement.

## 3. Key Metrics

### 3.1 CPU Saturation — Run Queue Depth

| Metric | Type | What It Tells Us |
|--------|------|------------------|
| `node_procs_running` | gauge | Processes currently running or in the run queue. **If this exceeds CPU count for sustained periods, the host is CPU-saturated.** |
| `node_procs_blocked` | gauge | Processes waiting for IO to complete. **Sustained non-zero = IO bottleneck.** |
| `node_load1 / node_load5 / node_load15` | gauge | Traditional load average. Compare to `count(node_cpu_seconds_total)` for the "load per core" ratio. |
| `node_context_switches_total` | counter | Voluntary + non-voluntary context switches. Rate per second is the key signal. |

**Typical queries:**

```promql
# Run queue depth (smoothed)
avg_over_time(node_procs_running[5m])

# Load per core ratio
node_load1 / count(node_cpu_seconds_total{mode="idle"})

# Context switch rate
rate(node_context_switches_total[5m])

# Processes waiting on IO
avg_over_time(node_procs_blocked[5m])
```

**Interpretation:**

| Signal | Healthy | Warning | Critical |
|--------|---------|---------|----------|
| Run queue / CPU cores | < 0.7 | 0.7 - 1.5 | > 1.5 |
| Context switches | < 20k/s (per core) | 20k - 50k/s | > 50k/s |
| Blocked processes | 0 | 1 - 3 | > 3 sustained |
| Load per core | < 0.7 | 0.7 - 2.0 | > 2.0 |

### 3.2 Pressure Stall Information (PSI)

PSI is the Linux kernel's first-class mechanism for measuring resource pressure. It reports the percentage of time tasks have been *delayed* waiting for a resource.

| Metric | Type | What It Tells Us |
|--------|------|------------------|
| `node_pressure_cpu_waiting_seconds_total` | counter | Total time tasks waited for CPU |
| `node_pressure_io_stalled_seconds_total` | counter | Time some tasks waited for IO (some = at least one task stalled) |
| `node_pressure_io_waiting_seconds_total` | counter | Time all tasks waited for IO (full = system is fully IO-bound) |
| `node_pressure_memory_stalled_seconds_total` | counter | Time some tasks waited for memory reclaim |
| `node_pressure_memory_waiting_seconds_total` | counter | Time all tasks waited for memory reclaim |

**Typical queries:**

```promql
# CPU pressure (10-second window avg)
avg_over time(node_pressure_cpu_waiting_seconds_total[5m]) * 100

# IO pressure (full stall — system is truly stuck on IO)
avg_over_time(node_pressure_io_stalled_seconds_total[5m]) * 100

# Memory pressure
avg_over_time(node_pressure_memory_stalled_seconds_total[5m]) * 100
```

**Interpretation:**

| PSI Metric | Normal | Elevated | Critical |
|-----------|--------|----------|----------|
| CPU pressure (some) | < 1% | 1-10% | > 10% |
| IO pressure (some) | < 0.5% | 0.5-5% | > 5% |
| IO pressure (full) | 0% | < 1% | > 1% |
| Memory pressure (some) | < 0.1% | 0.1-1% | > 1% |

**Why PSI beats load average:** Load average includes tasks in uninterruptible sleep (D state), which inflates the number even when the bottleneck is elsewhere. PSI directly measures *how long tasks waited*, giving a true severity signal.

### 3.3 Disk IO Pressure

| Metric | Type | What It Tells Us |
|--------|------|------------------|
| `rate(node_disk_io_time_seconds_total[5m])` | counter rate | Fraction of time disk was busy (per device) |
| `rate(node_disk_read_bytes_total[5m])` | counter rate | Read throughput |
| `rate(node_disk_written_bytes_total[5m])` | counter rate | Write throughput |
| `node_disk_io_weighted_seconds_total` | counter | IO time * queue depth. High value relative to `io_time_seconds_total` = deep queue = saturation. |
| `rate(node_disk_discard_time_seconds_total[5m])` | counter rate | TRIM/discard operations (can spike on container churn) |

**Saturation detection — weighted IO time vs busy time:**

```promql
# Average IO queue depth over the interval
rate(node_disk_io_weighted_seconds_total[5m]) / rate(node_disk_io_time_seconds_total[5m])

# Interpretation:
#   ~1.0   = single queue, disk is busy but not saturated
#   > 2.0  = multiple IO requests queued, disk is saturated
#   > 10.0 = severe saturation, deep queue
```

This ratio is the **most important single number** for disk pressure. A disk at 100% utilization with queue depth 1 is working hard but keeping up. A disk at 60% utilization with queue depth 8 has a bottleneck elsewhere (e.g., controller saturation, or NVMe thermal throttling).

### 3.4 Correlation — Composite Signals

Individual metrics are noisy. The real value comes from correlating them:

```promql
# CPU saturation detected by run queue + context switches
(
  avg_over_time(node_procs_running[5m])
  /
  count(node_cpu_seconds_total{mode="idle"})
) > 1.5
and
(
  rate(node_context_switches_total[5m]) > 50000
)

# IO pressure detected by blocked processes + weighted io queue depth
avg_over_time(node_procs_blocked[5m]) > 2
and
(
  rate(node_disk_io_weighted_seconds_total[5m])
  /
  rate(node_disk_io_time_seconds_total[5m])
) > 2

# Memory pressure: PSI + swap activity
avg_over_time(node_pressure_memory_stalled_seconds_total[5m]) * 100 > 1
or
(
  rate(node_vmstat_pswpin[5m]) > 0
  or
  rate(node_vmstat_pswpout[5m]) > 0
)
```

These composite signals reduce alert fatigue by requiring multiple independent indicators before firing.

## 4. Grafana Dashboard Row

Add a **"System Load"** row to the existing "Orbstack Host" dashboard (defined in `node-exporter.md`, Section 5). This row slots between the CPU row and the Memory row.

### Row: System Load

**Panel 1: Run Queue Depth**
- Type: Time series
- Queries:
  - `node_procs_running` — line
  - `node_procs_blocked` — line, dashed
  - Threshold line at `count(node_cpu_seconds_total{mode="idle"})` (CPU core count)
- Description: "Running processes vs CPU cores: sustained > core count = CPU saturation"

**Panel 2: Load Average per Core**
- Type: Time series
- Query: `node_load1 / count(node_cpu_seconds_total{mode="idle"})` as a line
  - Add `node_load5` and `node_load15` as dashed lines
- Threshold: 1.0 (line at y=1)
- Description: "Load / CPU core ratio. Above 1.0 means tasks are waiting."

**Panel 3: Context Switch Rate**
- Type: Time series
- Query: `rate(node_context_switches_total[5m])`
- Unit: ops/sec (suffix)
- Description: "Context switches per second. Sudden + sustained spikes suggest lock contention or IO completion storms."

**Panel 4: Disk IO Queue Depth**
- Type: Time series
- Query: `rate(node_disk_io_weighted_seconds_total[5m]) / rate(node_disk_io_time_seconds_total[5m])`
- Unit: none (ratio)
- Legend: `{{ device }}`
- Description: "Average IO queue depth. > 2 = disk saturation."

**Panel 5: PSI Pressure (if available)**
- Type: Time series
- Queries (as stacked %):
  - `avg_over_time(node_pressure_cpu_waiting_seconds_total[5m]) * 100`
  - `avg_over_time(node_pressure_io_stalled_seconds_total[5m]) * 100`
  - `avg_over_time(node_pressure_memory_stalled_seconds_total[5m]) * 100`
- Unit: percent (0-100)
- Legend: CPU / IO / Memory
- Description: "Pressure Stall Information: % of time tasks waited for each resource."

## 5. Alerts

### 5.1 Prometheus Alerting Rules

Add to the existing `node_exporter` alert group in Prometheus:

```yaml
groups:
  - name: node_exporter
    rules:
      # ── CPU Saturation ──
      - alert: HostCPUSaturation
        expr: |
          (
            avg_over_time(node_procs_running[5m])
            /
            count(node_cpu_seconds_total{mode="idle"})
          ) > 1.5
          and
          rate(node_context_switches_total[5m]) > 50000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Host CPU saturation: run queue {{ $value | humanize }}x core count"
          description: "Run queue depth exceeds CPU core count for 5 minutes with high context switch rate."

      - alert: HostCPUSaturationCritical
        expr: |
          (
            avg_over_time(node_procs_running[5m])
            /
            count(node_cpu_seconds_total{mode="idle"})
          ) > 2.0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Host CPU saturation CRITICAL: run queue {{ $value | humanize }}x core count"

      # ── IO Pressure ──
      - alert: HostIOPressureWaiting
        expr: avg_over_time(node_procs_blocked[5m]) > 3
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $value | humanize }} processes blocked on IO for 5 minutes"

      - alert: HostIOSaturation
        expr: |
          (
            rate(node_disk_io_weighted_seconds_total[5m])
            /
            rate(node_disk_io_time_seconds_total[5m])
          ) > 2.0
          and
          avg_over_time(node_procs_blocked[5m]) > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Disk IO saturation detected on {{ $labels.device }}"
          description: "Weighted IO queue depth > 2 with blocked processes. Device: {{ $labels.device }}"

      - alert: HostIOSaturationCritical
        expr: |
          avg_over_time(node_procs_blocked[10m]) > 5
          and
          (
            rate(node_disk_io_weighted_seconds_total[5m])
            /
            rate(node_disk_io_time_seconds_total[5m])
          ) > 5.0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Host IO saturation CRITICAL: {{ $value | humanize }} blocked processes, deep queue"

      # ── Memory Pressure (PSI based, if available) ──
      - alert: HostMemoryPressure
        expr: avg_over_time(node_pressure_memory_stalled_seconds_total[5m]) * 100 > 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Memory pressure detected (PSI > 1%)"
          description: "Tasks are waiting for memory reclaim {{ $value | humanize }}% of the time."
```

### 5.2 Alert Fatigue Prevention

These alerts are designed to be **actionable, not noisy**:

| Prevention | Mechanism |
|-----------|-----------|
| Composite conditions | CPU saturation requires BOTH high run queue AND high context switch rate. Context switches alone (e.g., a chatty poll loop) won't fire. |
| Duration gates | All alerts have `for: 5m`. Short spikes from cron jobs or container restarts are ignored. |
| Severity escalation | Warnings fire first; criticals require higher thresholds and longer duration. |
| Disambiguation | Separate alerts for CPU vs IO vs memory saturation. A single "load high" alert is useless — you need to know which resource. |

## 6. Interpretation Guide

Add this to the Grafana dashboard description or as a dashboard annotation.

### Reading the Signals

**Scenario A: High load, low CPU utilization**
- Load15 is high, CPU% is low
- Check: `node_procs_blocked` — likely IO bound
- Check: context switch rate — if high, heavy IO completion traffic
- Check: Disk weighted IO queue depth — if > 2, disk saturation
- Action: Investigate disk performance, check for swapping, look for container IO limits

**Scenario B: High load, high CPU utilization**
- Load15 is high, CPU% is high
- Check: `node_procs_running` > core count
- Check: Context switch rate — moderate? Then CPU-bound workload
- Action: Identify the heavy process, consider scaling or vertical CPU increase

**Scenario C: High context switches, low load, low CPU**
- Unusual pattern
- Check: What causes voluntary context switches? Synchronization primitives, IO completions, signal handling
- Check: `perf sched` on host if possible
- Action: Likely a chatty application doing rapid poll/epoll loops (e.g., a hot loop calling `select()`)

**Scenario D: Load spikes then plateaus**
- Load climbs to a value and stays there, even after CPU drops
- Cause: Load average includes D-state (uninterruptible sleep) tasks. If a process is stuck in D state (e.g., waiting on a stuck NFS mount), load stays high forever
- Action: Check for stuck mount points, hung NFS, dead kernel threads

## 7. Non-Goals

- **Per-process load breakdown**: Use `pidstat` or `htop` for ad-hoc investigation. Prometheus is for aggregate signals, not per-process profiling.
- **Custom eBPF probes**: PSI and existing node_exporter metrics are sufficient. eBPF-based profiling (e.g., `bcc`) is a separate deep-dive tool, not always-on monitoring.
- **CPU temperature / thermal throttling**: Node exporter has a `thermal_zone` collector, but Orbstack VM may not expose hardware sensors. Skip unless proven useful.
- **Container-level load**: Cgroup-level pressure stats are available via cAdvisor or the OTel Collector's cgroup receiver. This review is about the host only.

## 8. Future Considerations

- **Per-CPU run queue imbalance**: Some workloads pin processes to specific cores (e.g., via `taskset` or Docker's `--cpuset-cpus`). The aggregate `node_procs_running` hides imbalance. If needed, enable `node_schedstat` or use `perf stat` for per-core visibility.
- **eBPF-based scheduler monitoring**: For deep scheduler analysis (wakeup latency, preemption time), tools like `runqlat` (from BCC) or `pixie` provide per-microsecond histograms. Not always-on, but useful during incidents.
- **Cgroup PSI**: Linux 4.20+ supports per-cgroup PSI (`/sys/fs/cgroup/<path>/pressure/`). If container-level pressure becomes a concern, the OTel Collector's cgroup receiver can scrape this.
