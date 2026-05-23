---
decision: 现在就做
---

# Master Comparison: All Interception Approaches

**Date:** 2026-05-23
**Scope:** Systematic comparison of every interception/observation approach across the kyb infra stack,
evaluated along a fixed set of axes.

---

## Table of Contents

1. [The Approaches](#1-the-approaches)
2. [Comparison Axes](#2-comparison-axes)
3. [Individual Profiles](#3-individual-profiles)
4. [Master Comparison Matrix](#4-master-comparison-matrix)
5. [Decision Trees](#5-decision-trees)
6. [Combination Patterns](#6-combination-patterns)
7. [Anti-Patterns](#7-anti-patterns)

---

## 1. The Approaches

### 1.1 Proxy (MITM)

Bidirectional relay that terminates TLS on one side, re-encrypts on the other, and observes plaintext
traffic in the middle. The canonical example is `feishu-proxy`: sits between Feishu's WSS endpoint
and `cc-connect`, logging every WebSocket frame.

- **Where deployed:** cc-connect container (subprocess or sidecar)
- **Docs:** `docs/infra/reviews/proxy-intercept.md`
- **Real-world examples:** feishu-proxy, mitmproxy, sslsplit

### 1.2 Hook (Application-Level Callback)

The observed application natively supports emitting events at defined lifecycle points. Claude Code
hooks fire on PreToolUse, PostToolUse, SessionStart, etc. cc-connect v1.3.2 fires on
message.received, response.complete, session.crashed.

- **Where deployed:** Claude Code process (settings.json hooks), cc-connect (hooks.yaml)
- **Docs:** `docs/infra/handbook/hooks-ck-pipeline.md`, `docs/infra/reviews/claude-telemetry.md`
- **Real-world examples:** Claude Code hooks → emit-ck.sh → ClickHouse

### 1.3 Stdout Parse (Log Scraping)

Read the target process's stdout/stderr (via Docker log driver) and parse structured events from
log lines. No application modification needed, but depends on the application emitting useful
structured logs in the first place.

- **Where deployed:** All containers via Vector sidecar
- **Docs:** `docs/infra/reviews/sidecar-pattern.md`
- **Real-world examples:** Vector parsing sing-box JSON logs, PG log parsing, Redis log parsing

### 1.4 Docker Net (Network Namespace Sharing)

Place an observer container in the same network namespace as the target via
`--network container:<target>`. The observer can access `localhost` ports of the target without
going through Docker's network stack.

- **Where deployed:** Sidecar containers (Vector, Prometheus exporters)
- **Docs:** `docs/infra/reviews/sidecar-pattern.md` (Section 2)
- **Real-world examples:** vector-pg16 sharing postgres-16's network, pg-exporter scraping localhost

### 1.5 Feishu Webhook (cc-connect Native Webhook)

cc-connect's native hook engine POSTs structured JSON to a configurable HTTP endpoint (Kafka REST
Proxy). Different from Claude Code hooks -- this is a bridge-level (cc-connect) event system for
message lifecycle.

- **Where deployed:** cc-connect → Kafka REST Proxy → ClickHouse
- **Docs:** `docs/infra/reviews/hooks-kafka.md`
- **Real-world examples:** cc-connect hooks POST to Redpanda REST Proxy on port 8082

### 1.6 Sidecar (Co-Located Observer)

A separate container running alongside the target, sharing either network namespace, PID namespace,
volumes, or all three. The sidecar pattern is the deployment mechanism, not an interception
technique itself; but it enables several techniques (stdout parse via shared log mount, localhost
scrape via shared network, periodic polling).

- **Where deployed:** One Vector sidecar per infra service
- **Docs:** `docs/infra/reviews/sidecar-pattern.md`
- **Real-world examples:** vector-pg16, vector-clickhouse, postgres-exporter, sb-metrics-poller

### 1.7 eBPF (Kernel-Level Hooking)

Attach BPF programs to kernel tracepoints, kprobes, or socket operations to intercept syscalls,
network packets, or function calls without modifying userspace code. Requires kernel support
(5.3+/BPF_PROG_TYPE_SK_LOOKUP), elevated privileges, and careful version management.

- **Where deployed:** Not deployed. Mentioned as rejected alternative in `proxy-intercept.md`
- **Real-world examples:** Cilium, Pixie, Falco, tracee

### 1.8 SOCKS5 (Proxy Protocol)

A SOCKS5 proxy tunnels TCP/UDP traffic through a single entry point, allowing interception of
connection metadata (destination, bytes) but not payload content (TLS is opaque through the tunnel).

- **Where deployed:** sing-box (SOCKS5 on port 2080), used as egress proxy
- **Docs:** `docs/infra/reviews/sing-box-metrics.md`, `docs/infra/multi-cluster-boss-architecture.md`
- **Real-world examples:** sing-box SOCKS5 inbound, ALL_PROXY=socks5://kyb-infra-sing-box:2080

---

## 2. Comparison Axes

Every approach is rated on five dimensions:

| Axis | Scale | Meaning |
|------|-------|---------|
| **Complexity** | 1 (trivial) -> 5 (expert) | Implementation effort, dependencies, moving parts |
| **Reliability** | 1 (fragile) -> 5 (bulletproof) | Likelihood of data loss, false negatives, silent failures |
| **Completeness** | 1 (gaps) -> 5 (total) | What fraction of relevant signals reach the observer |
| **Maintainability** | 1 (painful) -> 5 (set-and-forget) | Ongoing burden: updates, config drift, breakage risk |
| **Failure Impact** | -5 (cascading) -> 0 (none) | If this breaks, does the observed system suffer? |

### 2.1 Axes Explained

**Complexity** considers:
- Lines of code / config to implement
- Number of new components introduced
- Learning curve for operators
- Integration effort with existing infra

**Reliability** considers:
- Buffer/deficit handling when downstream is down
- Retry architecture
- Silent failure modes
- Data loss window on crash

**Completeness** considers:
- Can it see all events or is there a filtering gap?
- Can it see payload content or just metadata?
- Can it capture historical data or only live?
- Is there a blind spot in the protocol stack?

**Maintainability** considers:
- Version coupling with observed system
- Kernel/OS dependency
- Config drift risk
- Upgrade burden
- Observability of the interception itself

**Failure Impact** considers:
- Does a crash in the observer block the observed?
- Does misconfiguration disrupt the main workflow?
- Can the main system detect and bypass a broken observer?
- Is the observer in the critical path?

---

## 3. Individual Profiles

### 3.1 Proxy (MITM)

```
Complexity:     4/5
Reliability:    3/5
Completeness:   5/5
Maintainability: 3/5
Failure Impact: -2/0
```

**Pros:**
- Sees EVERYTHING -- full payload, timing, protocol errors
- Can modify or replay traffic (replay-feishu)
- Protocol-aware (WebSocket frame boundaries preserved)
- Can insert synthetic probes (ping/pong latency)
- Fail-open via DNS fallback or configurable endpoint

**Cons:**
- Must terminate TLS, which means certificate management
- On the critical path -- if proxy crashes/delays, main flow is affected
- Must maintain feature parity with the upstream protocol
- Requires reconfiguring the target to point at the proxy
- Cannot intercept connections the target opens directly to other hosts

**Best for:** One specific protocol path that needs deep inspection (e.g., Feishu WSS).

### 3.2 Hook (Application-Level Callback)

```
Complexity:     2/5
Reliability:    4/5
Completeness:   3/5
Maintainability: 4/5
Failure Impact: -1/0
```

**Pros:**
- Application knows best what to emit -- structured, semantic events
- No TLS termination needed
- Fail-open by design (hook script exits 0 always)
- Decoupled from transport layer -- works regardless of network changes
- Easy to add enrichment (agent_id, project, metadata)

**Cons:**
- Only sees what the application chose to expose
- Missing events if the application doesn't have a hook for that lifecycle point
- Coupled to the application's release cycle (can't add hooks without app changes)
- Hook timeout can block the application (PreToolUse hooks are synchronous)
- High event volume needs batching

**Best for:** Application-level lifecycle events (tool use, session state, errors).

### 3.3 Stdout Parse (Log Scraping)

```
Complexity:     1/5
Reliability:    2/5
Completeness:   2/5
Maintainability: 3/5
Failure Impact: 0/0
```

**Pros:**
- Zero modification to the target application
- Works with anything that writes to stdout/stderr
- Docker log driver is always available, no extra config
- Vector/VRL can parse many formats (JSON, regex, grok)
- Observer failure has zero impact on the target

**Cons:**
- Only sees what the application logs -- may miss internal state
- Structured logging is inconsistent across applications
- Parsing is fragile -- log format changes break the pipeline silently
- High-volume logs can overwhelm the parsing pipeline
- Docker log driver can drop lines under pressure (non-blocking mode)
- No insight into binary protocols or encrypted traffic

**Best for:** Catching what's already being logged with minimal effort.

### 3.4 Docker Net (Network Namespace Sharing)

```
Complexity:     1/5
Reliability:    5/5
Completeness:   4/5
Maintainability: 5/5
Failure Impact: 0/0
```

**Pros:**
- Gives the observer full access to target's localhost ports
- No port exposure needed (ports stay internal to the namespace)
- Docker handles the plumbing -- one flag
- Observer restart doesn't affect the target
- Works for metrics scraping, health checks, debug endpoints

**Cons:**
- Only works for ports the target itself listens on
- Cannot intercept outbound connections from the target
- Network namespace must exist first (target must be running)
- Cannot share network across hosts
- Port conflicts if two targets listen on same port in same namespace

**Best for:** Metrics scraping from a service's Prometheus endpoint, sidecar health checks.

### 3.5 Feishu Webhook (cc-connect Native Webhook)

```
Complexity:     3/5
Reliability:    4/5
Completeness:   4/5
Maintainability: 4/5
Failure Impact: -1/0
```

**Pros:**
- Built into cc-connect natively -- no extra component needed
- Structured JSON, semantic event types
- Retries with backoff built in
- Kafka buffer absorbs ClickHouse downtime
- Fail-open: drops event after retries, doesn't block cc-connect

**Cons:**
- Only available if cc-connect has a hook system (v1.3.2+)
- Requires Kafka REST Proxy -- an additional dependency
- Event format is fixed by cc-connect, cannot add custom fields
- POST latency adds ~5-10ms per event

**Best for:** Bridge-level (cc-connect) event observability when the application already supports it.

### 3.6 Sidecar (Co-Located Observer)

```
Complexity:     2/5
Reliability:    3/5
Completeness:   3/5
Maintainability: 3/5
Failure Impact: 0/0
```

**Pros:**
- Composable -- attach/detach without touching the main container
- Shared network namespace enables localhost scraping
- Shared volumes enable log file access
- Independent lifecycle (can restart without affecting main service)
- Works with any existing container

**Cons:**
- Multiple containers per service increases management overhead
- Resource overhead per sidecar (~15 MB RAM for Vector)
- Bootstrapping requires the main container to exist first
- Sidecar restart can miss events (no buffer for scrape gaps)
- Sidecar log collection is redundant if Docker log driver already captures stdout

**Best for:** Adding observability to existing services without modifying them.

### 3.7 eBPF (Kernel-Level Hooking)

```
Complexity:     5/5
Reliability:    3/5
Completeness:   5/5
Maintainability: 1/5
Failure Impact: -3/0
```

**Pros:**
- Sees EVERYTHING -- syscalls, network packets, function calls
- No application modification, no proxy reconfiguration
- Can intercept kernel-level events (OOM, exec, file open)
- Works across all containers on a host
- Kernel-verified safety: BPF programs can't crash the kernel

**Cons:**
- **Extreme complexity**: BPF CO-RE, BTF, kernel version compatibility
- Kernel version coupling: programs may need rewrites for new kernels
- Requires `CAP_BPF` or `CAP_SYS_ADMIN` -- elevated privileges
- Limited to what kernel hooks exist (kprobe, tracepoint, sockmap)
- User space interaction is complex (BPF maps, perf events)
- Overhead at high event rates (context switches from kernel to userspace)
- Ingress/egress traffic inspection requires TC BPF or XDP -- even more complex

**Best for:** Deep system-level observability when everything else is insufficient.
**Worst for:** Simple payload logging -- overkill and under-powered (TLS is opaque).

### 3.8 SOCKS5 (Proxy Protocol)

```
Complexity:     1/5
Reliability:    4/5
Completeness:   1/5
Maintainability: 5/5
Failure Impact: -4/0
```

**Pros:**
- Zero application awareness (standard protocol, Go's `ProxyFromEnvironment`)
- Can see connection metadata (destination, bytes)
- Simple to deploy and configure
- SOCKS5 is universally supported

**Cons:**
- **Cannot see payload** -- TLS is tunneled, not terminated
- Only sees TCP/UDP, not other protocols
- If the SOCKS5 proxy goes down, all proxied traffic is blocked
- No inspection of DNS resolution (unless also intercepting DNS)
- Authentication adds complexity

**Best for:** Egress routing and basic traffic accounting.
**Worst for:** Payload inspection -- use a MITM proxy instead.

---

## 4. Master Comparison Matrix

### 4.1 Dimension Summary

| Approach | Complexity | Reliability | Completeness | Maintainability | Failure Impact | Overall Score* |
|----------|-----------|-------------|-------------|-----------------|----------------|----------------|
| Proxy (MITM) | 4 | 3 | 5 | 3 | -2 | 13 |
| Hook | 2 | 4 | 3 | 4 | -1 | 16 |
| Stdout Parse | 1 | 2 | 2 | 3 | 0 | 10 |
| Docker Net | 1 | 5 | 4 | 5 | 0 | 19 |
| Feishu Webhook | 3 | 4 | 4 | 4 | -1 | 17 |
| Sidecar | 2 | 3 | 3 | 3 | 0 | 14 |
| eBPF | 5 | 3 | 5 | 1 | -3 | 11 |
| SOCKS5 | 1 | 4 | 1 | 5 | -4 | 7 |

*Overall Score = sum of positive axes (complexity inverted: 5->1, 4->2, 3->3, 2->4, 1->5) + reliability + completeness + maintainability + failure impact (negative). This is a rough heuristic, not a mathematical truth.

### 4.2 What Each Approach Captures

| Can it see... | Proxy | Hook | Stdout | D.Net | F.Webhook | Sidecar | eBPF | SOCKS5 |
|---------------|-------|------|--------|-------|-----------|---------|------|--------|
| Payload content | YES | YES | If logged | N/A | YES | If logged | YES (unencrypted) | NO |
| Timing (latency) | YES | YES | If logged | N/A | YES | N/A | YES | If instrumented |
| Protocol errors | YES | If exposed | If logged | N/A | If exposed | If logged | YES | NO |
| Connection metadata | YES | N/A | If logged | N/A | YES | N/A | YES | YES |
| Application state | NO | YES | If logged | N/A | YES | N/A | PARTIAL | NO |
| Kernel events | NO | NO | NO | N/A | NO | NO | YES | NO |
| Historical replay | YES | YES | YES | N/A | YES (Kafka) | NO | NO | NO |
| Unmodified target | NO | NO | YES | YES | NO | YES | YES | YES |

### 4.3 Deployment Footprint

| Approach | New Components | Config Changes | Dependencies | Privileges | Per-Container Overhead |
|----------|---------------|----------------|-------------|------------|----------------------|
| Proxy (MITM) | 1 binary | Target endpoint URL | Go runtime (build) | None | ~5 MB + per-conn memory |
| Hook | 1 script | settings.json / hooks.yaml | curl, Python | None | ~sub-millisecond per event |
| Stdout Parse | 1 Vector config | None | Vector | docker.sock | ~15 MB (Vector sidecar) |
| Docker Net | 0 (runtime flag) | `--network container:X` | Docker | None | 0 |
| Feishu Webhook | 0 (built-in) | hooks.yaml | Kafka REST Proxy | None | ~0 (HTTP POST overhead) |
| Sidecar | 1 container | docker-compose or script | Docker | docker.sock | ~25 MB (Vector + config) |
| eBPF | 1 binary + BPF .o files | Kernel params | BTF, kernel headers | CAP_BPF, CAP_SYS_ADMIN | ~variable (map size) |
| SOCKS5 | 0 (sing-box exists) | ALL_PROXY env var | sing-box | None | ~0 (traffic routed) |

### 4.4 Failure Mode Matrix

| Approach | Observer Dead -> | Observer Slow -> | Misconfigured -> | Data Loss on Crash |
|----------|-----------------|------------------|------------------|-------------------|
| Proxy | Main flow breaks (fail-open mitigates) | Main flow delayed | Main flow can't connect | Currently captured data lost |
| Hook | No impact (fail-open) | Tool execution delayed (PreToolUse) | Events silently lost | Current batch lost |
| Stdout Parse | No impact | Logs buffer in Docker | Wrong parser = no events | Logs safe in Docker |
| Docker Net | No impact | N/A | Cannot start (Docker checks) | N/A |
| Feishu Webhook | Events dropped after retries | Minimal (5s timeout) | Events silently lost | Events lost (Kafka has buffer) |
| Sidecar | No impact | Buffer fills, data loss | May observe wrong container | Buffer lost on crash |
| eBPF | No kernel impact | Kernel drops events | Kernel rejection | Ring buffer overflow |
| SOCKS5 | **All downstream traffic blocked** | All traffic delayed | Traffic leak (misrouted) | Connection state lost |

### 4.5 Protocol Stack Layer

| Approach | OSI Layer | Protocol Scope | Encryption Visibility |
|----------|-----------|---------------|---------------------|
| Proxy (MITM) | 7 (Application) | Specific protocol (WS, HTTP) | Terminates TLS → sees plaintext |
| Hook | 7 (Application) | Application events | N/A (above encryption) |
| Stdout Parse | 7 (Application) | Whatever app logs | N/A (above encryption) |
| Docker Net | 3-4 (Network) | All localhost traffic | Encrypted or not (same as target) |
| Feishu Webhook | 7 (Application) | cc-connect lifecycle | N/A (above encryption) |
| Sidecar | 3-7 | Depends on sidecar type | Depends on sidecar |
| eBPF | 2-7 | All syscalls/packets/funcs | Raw packets (encrypted) |
| SOCKS5 | 5 (Session) | TCP/UDP connections | Encrypted (tunneled) |

---

## 5. Decision Trees

### 5.1 "I Need to See Payload Content"

```
Do you control the target application?
  ├── YES → Can the application emit events natively?
  │   ├── YES → Use Hook (simplest, most reliable)
  │   │   └── Example: Claude Code hooks, cc-connect webhooks
  │   └── NO → Can you insert a proxy between target and peer?
  │       ├── YES → Use Proxy (MITM)
  │       │   └── Example: feishu-proxy between cc-connect and Feishu WSS
  │       └── NO → Target connects to many peers dynamically
  │           ├── Is TLS termination acceptable?
  │           │   ├── YES → Use Proxy on the target's side
  │           │   │   └── Example: transparent proxy with iptables TPROXY
  │           │   └── NO → Use eBPF (sockmap/tc) for unencrypted traffic
  │           │       └── Note: eBPF cannot decrypt TLS
  │           └── N/A → All traffic is plaintext?
  │               └── Use tcpdump + PCAP analysis (not in this matrix)
  └── NO → Target is a third-party binary
      ├── Does it log structured data to stdout?
      │   ├── YES → Use Stdout Parse (simplest)
      │   └── NO → Can you wrap it in a proxy?
      │       ├── YES → Use Proxy (MITM)
      │       └── NO → Is the traffic TLS-encrypted?
      │           ├── YES → eBPF can't help (payload is encrypted)
      │           │   └── Alternative: Hook into the runtime (LD_PRELOAD, ptrace)
      │           └── NO → Use eBPF (complex but complete)
```

### 5.2 "I Need Connection Metadata Only"

```
Do you just need destination, bytes, timing?
  ├── YES → SOCKS5 proxy on ALL_PROXY
  ├── YES, but SOCKS5 failure would block traffic
  │   └── Use Docker Net + poller scraping /connections endpoint
  └── YES, and already have a proxy for other reasons
      └── Proxy + logging (covers payload + metadata)
```

### 5.3 "I Need All Observability with Zero Risk to Main System"

```
Primary axis: failure impact = 0 (must not affect target)
  ├── Best: Stdout Parse (zero coupling)
  ├── Best: Docker Net (separate container)
  ├── Best: Sidecar (independent lifecycle)
  ├── OK: Hook (fail-open design, but blocking hooks exist)
  ├── Risky: Proxy (in critical path, fail-open mitigates)
  ├── Risky: SOCKS5 (blocks all traffic if down)
  └── N/A: eBPF (kernel-level, could destabilize host)
```

### 5.4 "I Need Historical Replay"

```
Can you capture raw events for later replay?
  ├── YES → Proxy (replay-feishu, mitmproxy)
  ├── YES → Hook + ClickHouse (capture + replay from CK query)
  ├── YES → Feishu Webhook + Kafka (7-day retention, replay from topic)
  ├── PARTIAL → Stdout Parse (logs usually available, hard to replay)
  └── NO → Docker Net, Sidecar, eBPF, SOCKS5 (no capture, no replay)
```

### 5.5 "I Need to Monitor a Service Across All Protocols"

```
Does the service expose a management/debug API?
  ├── YES → Docker Net (localhost access) + poller
  │   └── Example: sing-box Clash API on :9090
  └── NO → 
      ├── Does it log to stdout?
      │   ├── YES → Stdout Parse
      │   └── NO → Proxy + eBPF (combine application-level + kernel-level)
```

---

## 6. Combination Patterns

No single approach is sufficient. Every production deployment uses a combination:

### 6.1 Full-Stack Observability (Current kyb Infra)

```
Layer 1: Hook (Claude Code)
  └── Every tool call, session event → emit-ck.sh → ClickHouse
  └── Coverage: application semantics

Layer 2: Feishu Webhook (cc-connect)
  └── Message lifecycle → Kafka REST Proxy → ClickHouse
  └── Coverage: bridge-level events

Layer 3: Stdout Parse (Vector sidecar)
  └── All containers' stdout → Vector → ClickHouse
  └── Coverage: everything that logs

Layer 4: Docker Net (sidecars)
  └── Prometheus exporters share target's network → localhost scraping
  └── Coverage: metrics from PG, Redis, Kafka

Layer 5: SOCKS5 (sing-box)
  └── ALL_PROXY routes all outbound traffic through sing-box
  └── Coverage: egress routing + traffic metadata

Layer 6: Proxy (feishu-proxy, proposed)
  └── MITM between cc-connect and Feishu WSS
  └── Coverage: raw WS frames, replay capability
```

**Layering principle:** Each layer fills the gaps of the one above it.

| Signal | Hook | F.Webhook | Stdout | D.Net | SOCKS5 | Proxy |
|--------|------|-----------|--------|-------|--------|-------|
| Tool calls | YES | NO | NO | NO | NO | NO |
| Session lifecycle | YES | YES | NO | NO | NO | NO |
| Message events | NO | YES | If logged | NO | NO | YES (WS) |
| Connection metadata | NO | NO | If logged | NO | YES | YES |
| Metrics (PG, Redis) | NO | NO | NO | YES | NO | NO |
| Raw WS frames | NO | NO | NO | NO | NO | YES |
| Replay capability | YES | YES (Kafka) | NO | NO | NO | YES |
| System health | NO | NO | YES (logs) | YES (health) | NO | PARTIAL |

### 6.2 Recommended Combinations by Scenario

**Incident response:**
```
Stdout Parse + Docker Net
  → Get logs and health metrics without any setup
  → Add Proxy if deep payload inspection is needed
```

**New service onboarding:**
```
Phase 1: Stdout Parse + Docker Net (5 minutes, zero config)
Phase 2: Hook if the service supports it (30 minutes)
Phase 3: Proxy for specific protocol paths (1-2 days)
```

**Cost-sensitive (limited resources):**
```
Hook (1 script, negligible overhead)
  + Stdout Parse (1 Vector daemon per host, not per container)
  → Use daemon mode instead of sidecar to minimize memory
```

**High-security / air-gapped:**
```
Hook (no network dependencies for the hook itself)
  + Sidecar (isolated from main service network)
  → Proxy is risky (TLS termination = security boundary)
  → SOCKS5 is risky (single point of failure for egress)
```

### 6.3 Data Flow Redundancy

Some signals can be captured by multiple approaches. When this happens, choose the most reliable:

| Signal | Available Via | Best Choice | Reason |
|--------|-------------|-------------|--------|
| Tool duration | Hook, Stdout Parse | Hook | Structured, semantic, already parsed |
| Session crash | Hook, Feishu Webhook, Docker Events | Hook | Fastest (fires immediately), most context |
| Connection bytes | SOCKS5, Stdout Parse, Proxy | SOCKS5 | Always available, doesn't depend on logging |
| Container restart | Docker Events, Stdout Parse | Docker Events | Fires at kernel level, can't miss |
| Latency | Hook, Proxy | Proxy | Nanosecond precision, monotonic clock |

---

## 7. Anti-Patterns

### 7.1 Proxy for Every Protocol Path

**Problem:** Running a MITM proxy for every connection the target makes.
- Each proxy is a new failure point
- Certificate management multiplies
- Latency accumulates

**Better:** Proxy only the critical path that needs deep inspection. For everything else, use
hooks or stdout parsing.

### 7.2 eBPF for Payload Logging

**Problem:** eBPF operates at the kernel level -- it sees packets, not messages. Reconstructing
application-level payloads from TCP segments requires TCP reassembly, which is:
- Complex (sequence numbers, retransmission, out-of-order delivery)
- Resource-intensive (per-connection state in BPF maps)
- Fragile across kernel versions

**Worse yet:** If traffic is TLS-encrypted (which it almost always is), eBPF sees ciphertext only.
You'd need to also hook the TLS library's encryption function -- which is application-specific,
may be in userspace, and varies per TLS implementation.

**Better:** Use a MITM proxy (terminates TLS) or application hooks (operates above encryption).

### 7.3 SOCKS5 for Payload Inspection

**Problem:** SOCKS5 tunnels TCP connections. The proxy sees CONNECT requests with destination
host:port, but once the tunnel is established, it only forwards raw bytes. TLS is opaque.

**This is by design:** SOCKS5 is a proxy protocol, not an interception protocol. If you need
payload visibility, SOCKS5 is the wrong tool.

### 7.4 Stdout Parse as the Only Pipeline

**Problem:** Relying solely on log parsing means:
- If the app doesn't log an event, it's invisible
- Log format changes break the pipeline silently
- Log levels change and critical events get filtered
- No way to add signals without modifying the app

**Better:** Use hooks or a proxy for the events you care about. Stdout parse should be the
catch-all, not the primary mechanism.

### 7.5 Hook Without Timeout

**Problem:** PreToolUse hooks are **synchronous** -- Claude waits for the hook to complete before
executing the tool. If the hook script hangs (slow network, deadlock in CK HTTP POST), the
entire Claude session blocks.

```json
// BAD: no timeout, default 60s
{"type": "command", "command": "/home/dev/.claude/hooks/emit-ck.sh"}

// GOOD: 5 second timeout
{"type": "command", "command": "/home/dev/.claude/hooks/emit-ck.sh", "timeout": 5}
```

**Rule:** Always set `timeout: 5` on PreToolUse hooks. PostToolUse hooks can be longer (they
don't block the tool), but keep them under 30s to avoid confusing Claude's internal scheduling.

### 7.6 Sidecar Without Restart Watch

**Problem:** Sidecar containers that depend on `network_mode: "service:<target>"` must be
recreated when the target container restarts. Docker does not automatically restart dependent
containers when the target's network namespace changes.

**Without a watch mechanism:**
```
1. Target restarts (new network namespace)
2. Sidecar still running (old network namespace is stale)
3. Sidecar tries to connect to localhost:xxxx
4. Fails silently → data loss until next patrol detects the issue
```

**Solution:** Deploy a watch script (as described in `sidecar-pattern.md` Section 6.3) or
use Docker Compose with `depends_on` (which handles restart ordering).

### 7.7 Mixing Hook and Proxy for the Same Signal

**Problem:** If both a hook and a MITM proxy emit the same event, you get duplicates. This
sounds fine (more data!) but causes:
- Metric doubles (event_count is 2x real)
- Alert fatigue (two alerts for one crash)
- Storage waste
- Confusion during debugging ("why did this event fire twice?")

**Solution:** Deduplicate at the ClickHouse level using `event_id` as a replaceable token
(`ReplacingMergeTree`) or use separate tables and a materialized view with `DISTINCT`. Better:
choose one approach per signal and stick with it.

---

## Appendix A: Decision Flowchart (Text)

```
START: What do you need to observe?
    │
    ├── Payload content?
    │   ├── Application has native hooks? → HOOK
    │   ├── Can insert proxy on specific path? → PROXY
    │   └── Neither? → eBPF (if unencrypted) or accept limitation
    │
    ├── Protocol metadata (dest, bytes, timing)?
    │   ├── All traffic routes through proxy? → SOCKS5 or PROXY
    │   ├── Service exposes debug API? → DOCKER NET + poller
    │   └── Service logs to stdout? → STDOUT PARSE
    │
    ├── Application lifecycle events?
    │   ├── Built-in webhook system? → FEISHU WEBHOOK / HOOK
    │   └── No hooks available? → STDOUT PARSE (if logged) or accept gap
    │
    ├── Kernel/host-level events?
    │   ├── Container lifecycle → DOCKER EVENTS (not in this matrix)
    │   └── Syscall/network-level → eBPF
    │
    └── How to deploy the observer?
        ├── New service? → SIDECAR
        ├── Existing service? → DOCKER NET (attach after the fact)
        └── Resource-constrained host? → Daemon (not sidecar)
```

---

## Appendix B: Related Documents

| Document | Focus | Approaches Covered |
|----------|-------|-------------------|
| `docs/infra/reviews/proxy-intercept.md` | Feishu WSS MITM proxy | Proxy (MITM) |
| `docs/infra/reviews/hooks-kafka.md` | cc-connect hooks → Kafka → CK | Feishu Webhook |
| `docs/infra/reviews/sidecar-pattern.md` | Vector + exporter sidecars | Sidecar, Docker Net, Stdout Parse |
| `docs/infra/reviews/claude-telemetry.md` | Claude Code tengu events | Hook |
| `docs/infra/reviews/sing-box-metrics.md` | Proxy traffic monitoring | SOCKS5, Stdout Parse |
| `docs/infra/reviews/docker-events.md` | Container lifecycle events | Docker Events (separate) |
| `docs/infra/handbook/hooks-ck-pipeline.md` | Claude hooks ops guide | Hook |
| `docs/infra/reviews/feishu-delivery.md` | Message delivery tracking | Hook (application-level) |

---

> /人◕ ‿‿ ◕人＼
