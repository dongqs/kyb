# Direct Network Connectivity to Office nuc8 — Options Analysis

> Date: 2026-05-22
> Context: The NUC8 at the office (public IP 58.247.98.202) runs a SOCKS5 proxy on port 2080 for office network access. Currently, all traffic routes through the sim jump host (47.100.71.220, Aliyun ECS), which has limited bandwidth ("小水管"), causing slow Docker pulls and timeouts.

## Current Setup

### Physical Network

| Component | Detail |
|-----------|--------|
| **macOS host** | Orbstack on home broadband (Shanghai, China) |
| **Router** | 192.168.8.1 (gateway, accessed via 192.168.1.1 admin page) |
| **Host public IP** | 183.193.176.107 (Shanghai, China Mobile/Unicom/Telecom) |
| **Proxy exit IP** | 103.181.1.45 (Tokyo, MonoCloud — via sing-box Shadowsocks) |
| **nuc8** | At office, IP 192.168.9.219/22, gateway 192.168.8.1 |
| **nuc8 public IP** | 58.247.98.202 (port 2080 TCP filtered from outside) |
| **Host Tailscale** | ✅ Active (utun6, IP 100.104.244.99, Tailscale 1.98.2) |

### Current Proxy Path

```
Container (ALL_PROXY=socks5://kyb-infra-sing-box:2080)
  → sing-box (Docker container, 192.168.97.2:2080)
    → nuc8-proxy outbound → 192.168.97.3:2081 (SSH tunnel on boss container)
      → SSH tunnel: ssh -L 0.0.0.0:2081:100.98.29.39:2080 sim
        → sim (47.100.71.220, Aliyun ECS)
          → Tailscale direct → nuc8 (100.98.29.39:2080)
            → SOCKS5 proxy → office network
```

### Tailscale Connection Matrix (from nuc8)

| Connection | Type | Latency |
|-----------|------|---------|
| nuc8 → sim | Direct | ~11ms |
| nuc8 → dongqs-mac (host) | Peer-relay (via sim) | ~17ms |
| nuc8 → shiwei-mac | Peer-relay (via sim) | ~17ms |

**Key finding**: `direct connection not established` between host (dongqs-mac) and nuc8.

## Why Tailscale P2P Fails

nuc8's `tailscale netcheck` output:
```
* IPv4: yes, 58.247.98.202:40726
* MappingVariesByDestIP: true
* PortMapping: (empty)
```

- **`MappingVariesByDestIP: true`** = ISP-level CGNAT (Carrier-Grade NAT)
- The public IP 58.247.98.202 is shared among multiple customers
- UDP 41641 port forwarding on the office router is ineffective due to CGNAT
- Both the home side and office side are behind restrictive NAT
- Result: Tailscale cannot establish direct P2P, must relay through sim

## Test Results

### Connectivity Tests

| Test | Result | Latency |
|------|--------|---------|
| Ping nuc8 (58.247.98.202, ICMP) | ✅ 2/2 received | 27ms avg |
| TCP port 22 (nuc8 direct) | ❌ Filtered | — |
| TCP port 2080 (nuc8 direct) | ❌ Filtered | — |
| SSH nuc8 via Tailscale (100.98.29.39) | ✅ | ~17ms |
| sing-box → nuc8:2080 via Tailscale | ✅ TCP open | ~23ms |
| Direct SOCKS5 from container (100.98.29.39:2080) | ✅ HTTP 302 | ~20ms |

### Latency Comparison (git.leyantech.com request)

| Route | Latency (warm) | Notes |
|-------|---------------|-------|
| Via SSH tunnel → sim → nuc8 | ~80ms | Current setup |
| Via direct SSH → nuc8 | ~100ms | Direct tunnel |
| Via sing-box → nuc8 (direct Tailscale) | Not tested | Would bypass SSH tunnel |

Both paths are comparable because all traffic converges on sim as the Tailscale relay.

## Options

### Option A: Eliminate SSH Tunnel (sing-box → nuc8 direct via Tailscale)

**Change**: In sing-box config, change `nuc8-proxy` outbound from `192.168.97.3:2081` to `100.98.29.39:2080`.

```diff
 {
   "type": "socks",
   "tag": "nuc8-proxy",
-  "server": "192.168.97.3",
-  "server_port": 2081
+  "server": "100.98.29.39",
+  "server_port": 2080
 }
```

Then kill the SSH tunnel: `kill 57472` (or `pkill -f "ssh.*-L.*2081"`)

**Effect**: Removes the SSH tunnel through sim as an intermediate hop. Sing-box connects directly to nuc8's SOCKS5 via Tailscale.

**Benefit**:
- Eliminates the "TCP over TCP" problem (SSH tunnel encapsulation of TCP traffic)
- Removes SSH tunnel instability (many zombie processes observed)
- Simpler architecture, one less layer
- Still routes through sim (as Tailscale peer-relay), but without double-TCP overhead

**Limitation**: Data still flows through sim (as Tailscale peer-relay). Bandwidth still limited by sim's Aliyun ECS specs.

**Effort**: Low (config change, 5 minutes)
**Risk**: Low (backup config first, rollback is trivial)

---

### Option B: Fix Tailscale P2P (Remove CGNAT on nuc8)

**Change**: Contact the office broadband ISP and request removal from CGNAT pool (i.e., request a real public IP). Then ensure UDP 41641 is forwarded on the office router to nuc8.

**Effect**: Tailscale can establish direct P2P between host and nuc8.

**Benefit**:
- Full internet bandwidth (home broadband ↔ office broadband)
- No sim dependency for data plane
- Lowest latency possible

**Effort**: Medium (call ISP, may need justification/extra fee)
**Risk**: Low (ISP-side change, revertible)

---

### Option C: Upgrade sim's Bandwidth (Temporary Relief)

**Change**: Upgrade the Aliyun ECS instance (sim) to a higher bandwidth tier. Or add a second ECS with higher bandwidth as a dedicated relay.

**Effect**: All proxy traffic benefits from higher relay bandwidth.

**Effort**: Low (console change, costs money)
**Impact**: Proportional to bandwidth upgrade (e.g., 10Mbps → 100Mbps = 10x improvement)
**Cost**: Ongoing monthly expense

---

### Option D: IP Whitelist on nuc8 for Direct TCP

**Change**: Add iptables rule on nuc8 to allow TCP connections to port 2080 from the home public IP (183.193.176.107).

```bash
# On nuc8, requires sudo (password needed, or NOPASSWD sudoers)
sudo iptables -A INPUT -s 183.193.176.107 -p tcp --dport 2080 -j ACCEPT
```

Then sing-box's nuc8-proxy (or this container) can connect directly to `58.247.98.202:2080`.

**Requirement**: sudo access on nuc8 (currently password-protected). Need to either:
- Set up NOPASSWD for specific commands in /etc/sudoers
- Or use `ssh -t` with password input (not recommended for automation)
- Or ask the nuc8 admin to run the command

**Benefit**: Completely bypasses sim for office network access.
**Effort**: Medium (needs interactive sudo)
**Risk**: Low (one iptables rule, revertible)

---

### Option E: Reverse Tunnel from nuc8

**Change**: Have nuc8 establish an SSH connection back to the host (or sim), creating a reverse tunnel for the SOCKS5 proxy.

```bash
# On nuc8, SSH back to host via Tailscale
ssh -R 0.0.0.0:2080:127.0.0.1:2080 dongqs@100.104.244.99
```

**Benefit**: Can work around NAT/firewall on both sides.
**Limitation**: Still goes through Tailscale (which is peer-relay via sim), same bandwidth limit.

**Effort**: Low (one SSH command)
**Impact**: Low (doesn't solve bandwidth problem)

---

### Option F: IPv6 (Not Feasible)

**Current state**: No IPv6 internet connectivity on either side.
- Container: only `::1` (loopback)
- nuc8: only link-local and Tailscape IPv6, no default IPv6 route
- macOS host: 8 parallel IPv6 default routes but no working IPv6 internet

**Verdict**: Not viable without ISP IPv6 support.

---

### Option G: Deploy a High-Bandwidth Relay Server

**Change**: Deploy a dedicated relay server (cloud VM with 100+ Mbps bandwidth) for Tailscale. Configure this new server as the primary relay.

**Effect**: All Tailscale traffic between host and nuc8 goes through the new high-bandwidth relay instead of sim.

**Requirement**: A cloud VM with good bandwidth and low latency to both Shanghai endpoints.

**Effort**: High (deploy new infrastructure)
**Cost**: Ongoing monthly expense
**Benefit**: Could dramatically improve throughput

---

### Option H: Docker Registry Mirror on nuc8 (Targeted Fix)

**Change**: If the slowness is primarily about Docker pulls to/from a private registry, set up a Docker pull-through cache or registry mirror on nuc8.

**Effect**: Docker pulls are served from local cache on nuc8, bypassing the bandwidth bottleneck for subsequent pulls.

**Benefit**: Targeted fix for the most painful use case.
**Effort**: Medium (deploy registry mirror container on nuc8)

---

## Recommended Path

### Immediate (Configuration Change, No Cost)

**Step 1**: Modify sing-box config to connect directly to nuc8 via Tailscale, eliminating the SSH tunnel:

```bash
# 1. Backup and edit sing-box config
cd ~/.config/sing-box
cp config.json config.json.last-good
```

Edit config.json: change nuc8-proxy outbound server from `192.168.97.3:2081` to `100.98.29.39:2080`.

```bash
# 2. Validate and reload
sing-box check -c config.json
docker kill -s HUP kyb-infra-sing-box

# 3. Kill the SSH tunnel (no longer needed)
kill $(lsof -ti :2081) # Find PID on port 2081

# 4. Verify
ALL_PROXY=socks5://kyb-infra-sing-box:2080 curl -sI https://git.leyantech.com
```

**Result**: Eliminates "TCP over TCP" overhead, removes SSH tunnel instability. Still uses sim as relay but with a cleaner path.

### Medium-Term (High Impact)

**Step 2a**: Request ISP to remove CGNAT on nuc8's office broadband → enables Tailscale P2P direct → full bandwidth, no relay required.

**OR Step 2b**: Deploy a higher-bandwidth relay server if P2P is not feasible.

**OR Step 2c**: Set up IP whitelist on nuc8 (if sudo access available) → completely bypass both sim and Tailscale for the proxy path.

## Key Insights

1. **Ping works to nuc8's public IP** but TCP does not. This is the nuc8's firewall (or CGNAT), not a network failure.

2. **Tailscale works from the container** (SSH to nuc8, ping to Tailscale IPs) because the macOS host runs Tailscale and Orbstack routes `100.x.y.z` traffic through it.

3. **The sing-box container can also reach nuc8 via Tailscale** (`nc -zv 100.98.29.39 2080` succeeds), making the SSH tunnel redundant.

4. **sim is both the SSH tunnel endpoint AND the Tailscale peer-relay.** Even eliminating the SSH tunnel, all data still flows through sim as a Tailscale relay.

5. **The root cause is CGNAT on nuc8's ISP.** Until this is resolved, or an alternative is deployed, sim remains the bottleneck.
