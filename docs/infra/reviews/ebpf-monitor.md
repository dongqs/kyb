---
decision: 不应该做
---

# eBPF Monitor: Kernel-Level Observability for Infra

**Author:** Boss
**File:** `docs/infra/reviews/ebpf-monitor.md`
**Status:** Draft / Feasibility Study
**Date:** 2026-05-23

## 1. Overview

eBPF (extended Berkeley Packet Filter) enables safe, programmable kernel instrumentation
without modifying kernel source or loading kernel modules. For our infra observability,
eBPF can capture three critical data planes that traditional metrics (cAdvisor, Prometheus
node_exporter) cannot:

| Data Plane | What It Reveals | Why Existing Tools Miss It |
|------------|----------------|---------------------------|
| **Container syscalls** | execve, connect, open, clone — every syscall per container | cAdvisor gives CPU/mem/io cgroup stats, not *what* the process is doing |
| **Network flows** | TCP/UDP connections per second, DNS queries, socket lifetime | Prometheus netstat gives aggregate counters, not per-flow tuples |
| **File access** | Which files are read/written, by which process, how often | node_exporter disk stats give block-level ops, not file paths |

This document evaluates whether eBPF-based monitoring is feasible on our Orbstack-hosted
infra, what it would look like, and whether the complexity is justified.

---

## 2. Architecture

### 2.1 High-Level Design

```
┌─────────────────────────────────────────────────────────────────┐
│                      Orbstack Host Kernel                        │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │  Syscall      │  │  Network     │  │  File Access │          │
│  │  Tracepoints  │  │  TC Hook     │  │  LSM Probe   │          │
│  │  (tracepoint) │  │  (cls_bpf)   │  │  (kprobe)    │          │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │                 │                 │                    │
│         ▼                 ▼                 ▼                    │
│  ┌──────────────────────────────────────────────────────┐       │
│  │              eBPF Maps (per-CPU hash maps)           │       │
│  │  • syscall_counts[pid][syscall_id] → count          │       │
│  │  • flow_tuples[src_ip:dst_ip:dport] → bytes/pkts    │       │
│  │  • file_ops[pid][inode] → read_bytes/write_bytes    │       │
│  └──────────────────────┬───────────────────────────────┘       │
│                         │                                        │
│                         ▼                                        │
│  ┌──────────────────────────────────────────────────────┐       │
│  │              Userspace Agent (bpf-loader)            │       │
│  │  • Reads perf_buffer / map batches every N seconds   │       │
│  │  • Enriches with container_id (cgroup v2)            │       │
│  │  • Normalizes and forwards                          │       │
│  └──────────┬───────────────────────────────────────────┘       │
└─────────────┼───────────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────┐    ┌──────────────────────────────┐
│  Vector / Fluent Bit    │───▶│  ClickHouse                 │
│  (metrics + events)     │    │  • ebpf.syscall_events      │
│                         │    │  • ebpf.flow_logs           │
│                         │    │  • ebpf.file_events         │
│                         │    │  • ebpf.metrics_5m          │
└─────────────────────────┘    └──────────────────────────────┘
```

### 2.2 Container Identity

The key challenge is mapping kernel events to Docker containers. Since Orbstack runs
containers on cgroup v2, every kernel event carries the cgroup ID of the process:

```
/sys/fs/cgroup/system.slice/docker-<container_id>.scope/
```

The eBPF program reads `bpf_get_current_cgroup_id()` and the userspace agent maps
cgroup IDs to container names via Docker API.

### 2.3 Event Enrichment Pipeline

```
Raw eBPF event (kernel)
  │
  ├─ cgroup_id → container_id (Docker API lookup, cached TTL 60s)
  ├─ pid → process_name (/proc/pid/comm, cached TTL 30s)
  ├─ timestamp_ns → human timestamp
  └─ enriched JSON → ClickHouse
```

---

## 3. Container Syscall Monitoring

### 3.1 What to Capture

| Syscall | Signal | Detection Value |
|---------|--------|----------------|
| `execve` | New process spawned | Malware, unexpected binaries, cron jobs |
| `clone` / `fork` | Process fork bomb | Resource abuse, runaway agents |
| `connect` | Outbound connection | C2 beaconing, unauthorized egress |
| `bind` | Listening socket | Unauthorized service, port conflict |
| `open` (write) | File written | Config tampering, log rotation |
| `unlink` | File deleted | Log tampering, cleanup anomalies |
| `mount` | New mount | Container escape attempt |
| `ptrace` | Process attach | Debugger activity, credential dumping |
| `setuid` / `setgid` | Privilege escalation | Container escape, misconfiguration |

### 3.2 eBPF Program Design (tracepoint)

```c
// Pseudo-code: syscall tracepoint program
SEC("tracepoint/syscalls/sys_enter_execve")
int trace_execve(struct trace_event_raw_sys_enter *ctx)
{
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u64 cgroup_id = bpf_get_current_cgroup_id();
    struct event_t event = {};

    event.pid = pid;
    event.cgroup_id = cgroup_id;
    event.syscall_id = ctx->id;
    event.timestamp = bpf_ktime_get_ns();
    // Read filename from args (bpf_probe_read_user)
    bpf_probe_read_user_str(event.filename, sizeof(event.filename),
                            (const char *)ctx->args[0]);

    bpf_perf_event_output(ctx, &events, BPF_F_CURRENT_CPU, &event, sizeof(event));
    return 0;
}
```

### 3.3 Filtering Strategy

Raw syscall tracing is **extremely noisy** (~10^5 events/sec/container). We use three
levels of filtering:

1. **In-kernel BPF filter**: Only record specific syscall IDs (not all ~300 syscalls)
2. **Rate limiting**: Per-CPU hash map with 1-second buckets; drop if >100 events/sec
   per syscall type
3. **Process allowlist/blocklist**: Only trace processes matching configured patterns
   (e.g., ignore `sleep`, `bash` idle loops)

### 3.4 Aggregation

Instead of raw events, emit pre-aggregated metrics:

```sql
-- ebpf.metrics_5m (materialized from raw events)
CREATE TABLE ebpf.metrics_5m
(
    window_start     DateTime,
    container_id     String,
    syscall_name     String,
    count            UInt64,
    unique_pids      UInt64,
    rate_per_sec     Float64
) ENGINE = SummingMergeTree()
ORDER BY (window_start, container_id, syscall_name);
```

---

## 4. Network Flow Monitoring

### 4.1 What to Capture

| Flow Attribute | Source | Purpose |
|---------------|--------|---------|
| src_ip:src_port | kernel skb | Identify source container (via cgroup + socket) |
| dst_ip:dst_port | kernel skb | External destination logging |
| protocol (TCP/UDP) | kernel skb | Protocol distribution |
| bytes/packets | kernel skb | Bandwidth accounting |
| tcp_flags | kernel skb | Connection lifecycle (SYN/FIN/RST) |
| dns_query | kprobe on `__dns_query` | DNS resolution monitoring |
| process_name | cgroup + pid | Which process made the connection |

### 4.2 eBPF Program Design (TC hook)

TC (Traffic Control) ingress/egress hooks attach to container veth interfaces:

```c
// Pseudo-code: TC ingress program
SEC("tc/ingress")
int tc_ingress(struct __sk_buff *skb)
{
    u64 cgroup_id = bpf_get_current_cgroup_id();

    // Parse IP header
    struct iphdr ip;
    bpf_skb_load_bytes(skb, 0, &ip, sizeof(ip));

    // Parse TCP/UDP header for ports
    struct tcphdr tcp;
    bpf_skb_load_bytes(skb, sizeof(ip), &tcp, sizeof(tcp));

    // Aggregate in map
    struct flow_key_t key = {
        .cgroup_id = cgroup_id,
        .daddr = ip.daddr,
        .dport = tcp.dest,
        .protocol = ip.protocol,
    };

    struct flow_metrics_t *val = bpf_map_lookup_elem(&flow_map, &key);
    if (val) {
        val->packets++;
        val->bytes += skb->len;
    } else {
        // Initialize new entry
    }

    return TC_ACT_OK;
}
```

### 4.3 Aggregation Strategy

TC hooks process **every packet**, so raw storage is infeasible. Use:

1. **In-kernel aggregation** (hash maps with LRU eviction)
2. **Userspace flushes every 10 seconds** → aggregated flow records
3. **Pre-aggregated ClickHouse table**:

```sql
CREATE TABLE ebpf.flow_logs
(
    window_start     DateTime,
    window_end       DateTime,
    container_id     String,
    process_name     String,
    dst_ip           IPv6,
    dst_port         UInt16,
    protocol         Enum('tcp', 'udp'),
    packets          UInt64,
    bytes            UInt64,
    flow_count       UInt64   -- unique 5-tuples in this window
) ENGINE = SummingMergeTree()
ORDER BY (window_start, container_id, dst_ip, dst_port);
```

---

## 5. File Access Monitoring

### 5.1 What to Capture

| Event | eBPF Hook | Purpose |
|-------|-----------|---------|
| File open (read) | tracepoint:syscalls/sys_enter_openat | Which files are read |
| File open (write) | tracepoint:syscalls/sys_enter_openat + O_WRONLY| Which files are written |
| File read/write | kprobe:vfs_read / vfs_write | I/O volume per file |
| File delete | tracepoint:syscalls/sys_enter_unlinkat | Log/temp file cleanup |
| File rename | tracepoint:syscalls/sys_enter_renameat | Atomic write detection |
| Symlink creation | tracepoint:syscalls/sys_enter_symlinkat | Suspicious link farm |

### 5.2 Path Resolution

File monitoring requires careful design to avoid leaking kernel memory:

```c
// Path resolution via d_path() — can't call directly in BPF
// Alternative: capture inode + mount_id, resolve in userspace

SEC("kprobe/vfs_read")
int trace_vfs_read(struct pt_regs *ctx)
{
    struct file *file = (struct file *)PT_REGS_PARM1(ctx);
    struct inode *inode;

    bpf_probe_read_kernel(&inode, sizeof(inode), &file->f_inode);
    u64 inode_nr = BPF_CORE_READ(inode, i_ino);
    dev_t dev = BPF_CORE_READ(inode, i_sb, s_dev);

    struct file_event_t event = {
        .pid = bpf_get_current_pid_tgid() >> 32,
        .cgroup_id = bpf_get_current_cgroup_id(),
        .inode = inode_nr,
        .dev = dev,
        .op = OP_READ,
        .size = (u64)PT_REGS_PARM3(ctx),
        .timestamp = bpf_ktime_get_ns(),
    };

    bpf_perf_event_output(ctx, &file_events, BPF_F_CURRENT_CPU,
                          &event, sizeof(event));
    return 0;
}
```

### 5.3 Userspace Path Resolution

The inode:dev pair maps to a filesystem path in userspace via `readlink /proc/pid/fd/N`
or `stat(/proc/pid/root/path)`. This is expensive, so:

- Batch resolve: collect all unique inode:dev pairs, resolve once per flush
- Cache resolved paths in LRU (TTL 300s)
- Only track files under monitored paths (`/data/`, `/app/`, `/etc/`, config files)

---

## 6. Orbstack Feasibility Assessment

### 6.1 Environment Probe Results

Probed on `7.0.5-orbstack-00330-ge3df4e19b0a0-dirty` (Orbstack custom kernel):

| Feature | Host | Privileged Container | Notes |
|---------|------|---------------------|-------|
| BTF (`/sys/kernel/btf/vmlinux`) | YES | NO (not mounted) | Must mount `-v /sys/kernel/btf:/sys/kernel/btf` |
| BPF fs (`/sys/fs/bpf`) | YES | NO (not mounted) | Must mount `-v /sys/fs/bpf:/sys/fs/bpf` |
| Tracefs (`/sys/kernel/debug/tracing`) | YES | NO (debugfs not mounted) | Must mount `-v /sys/kernel/debug:/sys/kernel/debug` |
| cgroup v2 | YES | YES (`0::/`) | Works inside containers |
| BPF syscall | YES | YES (from privileged) | bpf() syscall is available |
| `unprivileged_bpf_disabled` | 2 | 2 | Unprivileged BPF disabled; no impact for privileged containers |
| `perf_event_paranoid` | 2 | 2 | Safe — allows perf_event_open for root |
| libbpf / CO-RE | YES | Depends on BTF mount | BTF must be mounted or embedded |

### 6.2 Required Container Capabilities

The monitoring agent container needs:

```yaml
# Docker Compose fragment
ebpf-agent:
  image: kyb/ebpf-agent:latest
  privileged: true                # CAP_BPF + CAP_SYS_ADMIN + access to perf_event_open
  pid: host                       # Read /proc for process metadata
  volumes:
    - /sys/kernel/btf:/sys/kernel/btf:ro           # CO-RE BPF with BTF
    - /sys/kernel/debug:/sys/kernel/debug:ro       # Tracepoints/kprobes
    - /sys/fs/bpf:/sys/fs/bpf                      # BPF maps pinning
    - /var/run/docker.sock:/var/run/docker.sock:ro # Container metadata
    - /proc:/host/proc:ro                          # Process metadata
```

### 6.3 Orbstack-Specific Limitations

1. **Custom kernel**: Orbstack uses a custom Linux kernel (`7.0.5-orbstack-*`).
   CO-RE eBPF (BTF-powered) eliminates kernel version dependency — **no issue**.
   However, if Orbstack ships a BTF-less kernel in the future, CO-RE breaks.

2. **No kprobe on all functions**: Orbstack kernel strips some symbols.
   Our probe showed empty kprobe list. Critical functions (`vfs_read`, `tcp_v4_connect`,
   `__dns_query`) may be unavailable for kprobe attachment. **Risk: MEDIUM**.

3. **TC hook on veth**: Orbstack's virtual Ethernet layer may not expose standard
   veth interfaces to TC hooks. Alternative: use **cgroup/skb** or **cgroup/sock** 
   programs instead of TC. **Risk: MEDIUM**.

4. **Docker socket**: Orbstack exposes the Docker socket, so container identity
   lookup is straightforward. **No issue**.

5. **Performance**: eBPF on Orbstack's virtualization layer adds overhead for
   context switching between guest and host kernel. For high-throughput monitoring
   (every packet flow), this could cause measurable latency. Mitigation: heavy
   in-kernel aggregation, minimize perf_buffer events.

### 6.4 Verdict: Feasible with Caveats

```
Feasibility: ✅ YES, but with constraints
╔══════════════════════════════════════════════════════════════╗
║  Component          Feasible  Risk  Alternative              ║
╠══════════════════════════════════════════════════════════════╣
║  Syscall monitoring  ✅ YES    LOW   auditd + ausearch       ║
║  Network flows       ✅ YES    MED   cgroup sock instead of  ║
║                                             TC hook          ║
║  File access         ⚠️ PARTIAL HIGH  fanotify / inotify     ║
║  DNS query capture   ⚠️ PARTIAL HIGH  nftables + nflog       ║
╚══════════════════════════════════════════════════════════════╝
```

---

## 7. Implementation Plan

### Phase 0: PoC (1 week)

- [ ] Write a single eBPF program that captures `execve` syscalls via tracepoint
- [ ] Run in privileged container on Orbstack with `--pid=host`
- [ ] Verify events arrive in userspace perf_buffer
- [ ] Enrich with container name via Docker API
- [ ] Benchmark: events/sec, CPU overhead, memory overhead

**Success criteria**: 10,000 events/sec with <2% CPU overhead on host.

### Phase 1: Container Syscall Baseline (3 days)

- [ ] Deploy syscall monitor to collect 24-hour baseline
- [ ] Identify top-10 syscalls per container type
- [ ] Create ClickHouse schema: `ebpf.syscall_events`, `ebpf.syscall_metrics_5m`
- [ ] Build Grafana dashboard: syscall rate by container, anomaly detection

**Deliverable**: "What normal looks like" for each container.

### Phase 2: Network Flow Monitoring (1 week)

- [ ] Implement TC ingress/egress or cgroup/sock program
- [ ] In-kernel flow aggregation with LRU eviction
- [ ] Userspace flush → ClickHouse `ebpf.flow_logs`
- [ ] Build Grafana dashboard: top talkers, connection rate, protocol mix

**Deliverable**: Per-container network flow logs with 10s granularity.

### Phase 3: File Access Monitoring (1 week, HIGH risk)

- [ ] Implement kprobe on `vfs_read` / `vfs_write` (if available on Orbstack)
- [ ] Implement tracepoint on `sys_enter_openat`
- [ ] Userspace inode→path resolver with LRU cache
- [ ] Build Grafana dashboard: hot files, write-heavy containers

**Deliverable**: Top-N file access events per container.

### Phase 4: Alerting and Anomaly Detection (3 days)

- [ ] Baseline deviation alerts (syscall rate spikes, new syscall types)
- [ ] Known-bad syscall alerts (e.g., `ptrace`, `mount` in non-build containers)
- [ ] DNS query threshold alerts
- [ ] File access outside expected paths

---

## 8. Comparison with Alternatives

### 8.1 vs. OpenTelemetry (Current Direction)

| Dimension | eBPF Monitor | OTel Patrol |
|-----------|-------------|-------------|
| Depth | Kernel-level — captures everything | Application-level — only what code instruments |
| Setup | Complex: privileged container, kernel deps | Simple: shell script + JSON file |
| Security | Needs CAP_BPF + CAP_SYS_ADMIN | Zero special privileges |
| Data volume | Very high (10^5 events/sec) | Low (1 trace per patrol round) |
| Visibility | Unknown unknowns (zero-day anomalies) | Known flows (we know what to measure) |
| Operational cost | High (map tuning, event loss, kernel compat) | Low (file→vector→CK) |

### 8.2 vs. Traditional Linux Tools

| Tool | What It Captures | Limitation |
|------|-----------------|------------|
| `auditd` | Syscalls via audit subsystem | High overhead, post-processing needed, not container-aware by default |
| `tcpdump` | Full packet capture | Raw pcap, no container identity, high storage |
| `strace` | Per-process syscalls | Attaches to process, cannot daemonize for whole system |
| `inotify`/`fanotify` | File access events | Per-directory watch, limited scalability |
| `nftables` + `nflog` | Network packets | No application-level enrichment |

### 8.3 Recommendation

**Do not implement eBPF monitoring at this time.**

Rationale:

1. **Our infra is not large enough.** We run ~12 containers on a single host.
   eBPF shines at scale (100+ hosts, 1000+ containers) where anomaly detection
   across a fleet justifies the complexity.

2. **OTel is already solving the right problems.** OTel patrol traces give us
   end-to-end visibility for the critical path (patrol rounds, check failures,
   heartbeat loss). The gaps that eBPF would fill (unexpected syscalls, unknown
   network flows) are not our current failure modes.

3. **Orbstack adds risk without benefit.** The custom kernel and virtualization
   layer introduce unknowns for kprobe/tracepoint availability. We would spend
   more time debugging eBPF infrastructure than debugging our actual infra.

4. **Maintenance cost.** Every Orbstack update could break eBPF programs.
   CO-RE mitigates this for BPF code, but kernel hook availability and
   performance characteristics could change silently.

5. **Alternatives are cheaper.** For the specific use cases:
   - **Container exec events**: `docker events --filter 'type=container'` + WebSocket
   - **Network flows**: Docker's built-in `docker stats` + `conntrack` on host
   - **File changes**: Bind-mount logs to host and monitor with `inotifywait`

### 8.4 When to Revisit

Revisit eBPF monitoring when one of these triggers occurs:

1. **We add 5+ hosts** to the infra (multi-host fleet makes eBPF's signal-to-noise
   ratio much better)
2. **A security incident** occurs that OTel + container logs couldn't explain
   (unknown egress, unexpected binary execution)
3. **Orbstack provides native eBPF support** (e.g., mounts tracefs/BPF fs into
   containers by default, or offers an eBPF-as-a-service API)
4. **A clear eBPF use case emerges** that no existing tool can address (e.g.,
   "why is this container using 10x more CPU than last week at 3am")

---

## 9. Appendix: Quick Reference

### 9.1 Orbstack Capability Checklist

```bash
# From host (SSH into Orbstack VM)
cat /sys/kernel/btf/vmlinux | head -c 16          # BTF exists
mount | grep bpf                                    # BPF fs mounted
cat /sys/kernel/debug/tracing/available_tracers    # Tracepoints available

# From privileged container
docker run --rm --privileged --pid=host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  alpine bpftool feature probe
```

### 9.2 CO-RE BTF Embedding

```bash
# Embed BTF into binary at build time (reduces runtime dependency)
bpftool btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h

# Or embed .BTF section directly:
# Using go:github.com/cilium/ebpf with btf.Internal() embedding
```

### 9.3 Key BPF System Calls

```c
// Minimal test — load a trivial BPF program
union bpf_attr attr = {
    .prog_type = BPF_PROG_TYPE_RAW_TRACEPOINT,
    .insn_cnt = 2,
    .insns = (__aligned_u64)&insns,
    .license = (__aligned_u64)"GPL",
    .prog_flags = BPF_F_SLEEPABLE,
};
int fd = syscall(SYS_bpf, BPF_PROG_LOAD, &attr, sizeof(attr));
```

---

*This document is a feasibility study. The conclusion is: defer eBPF monitoring
until scale or security needs justify the complexity. Invest in OTel patrol traces
and Docker event logging instead.*
