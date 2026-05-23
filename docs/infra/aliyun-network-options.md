# Aliyun Network Connectivity Options

> Survey: 2026-05-22
> Context: improving network connectivity for kyb infrastructure, sim ECS has ~50 CNY credit

---

## 1. click-rest bin/sae File

The file at `git.leyantech.com/quick-n-dirty/click-rest/-/raw/master/bin/sae` was **not accessible** -- both the raw URL (302 redirect to login) and the glab API (403 Forbidden) returned errors. The glab token does not have access to the `quick-n-dirty` group.

**What we know indirectly**: The `java-example` project in the `leyan` group deploys to Alibaba SAE. The click-rest `bin/sae` likely contains a similar SAE deployment script (probably wrapping `aliyun sae` CLI or a SAE API call to deploy an application).

**Status**: Unable to read. Would need repo access granted or a local clone.

---

## 2. Aliyun Credentials & Docs Found

### Existing Docs in project
| File | Content |
|------|---------|
| `docs/network-issues.md` | Detailed build/run network flows, Aliyun mirrors (mirrors.aliyun.com), proxy setup |
| `docs/tailscale.md` | Tailscale topology (sim, nuc8, pang-s2, shiwei-mac) |
| `docs/infra/network-capture.md` | kyb-infra-sing-box proxy routing (SOCKS5 relay to Relay-JP2) |
| `docs/infra/survey-remaining.md` | Mentions `java-example` deploys to "Alibaba SAE (serverless)" |

### Credentials
- **No Aliyun credentials found** in `.env` files, bash profiles, or `~/.aliyun/` directory on sim
- **No aliyun CLI installed** on either local dev machine or sim
- **No ACCESS_KEY / ALICLOUD env vars** found on sim
- Sim has **no Python packages for Aliyun SDK** installed

---

## 3. Aliyun Services Currently Used

### Sim ECS Instance (`ecs.e-c1m1.large`)
| Property | Value |
|----------|-------|
| Instance Type | `ecs.e-c1m1.large` (经济型 e 实例, part of Aliyun "99 计划") |
| vCPU | 2 cores |
| RAM | 2 GiB |
| Disk | 40 GiB ESSD (15G used, 23G free) |
| Region | **cn-shanghai** |
| VPC | `vpc-uf6w02zm7jbzjh72zzj6h`, CIDR `172.16.0.0/12` |
| Internal IP | `172.19.67.144/20` |
| EIP | **47.100.71.220** |
| Bandwidth | **3 Mbps fixed** (unlimited traffic) |
| OS | Ubuntu 24.04.1 LTS |
| Cost | **99 CNY/year** (already paid) |
| Remaining Credit | **~50 CNY** |

### Current Services Running
| Service | Status | Notes |
|---------|--------|-------|
| Docker Engine | Running (v28.0.0) | 3 containers (all Exited), 15 images |
| Topo | Exited | Was running, stopped 37h ago |
| ClickHouse | Exited | Last active 14 months ago |
| Tailscale | Active | IP 100.113.24.32, with relay port 40000 |
| Nginx/Web | Running | Ports 80, 443, 4330, 44321-44323 listening |
| SSH | Running | Port 22 |

### Sim ECS Bandwidth Reality (Tested)
| Target | Speed | Notes |
|--------|-------|-------|
| mirrors.aliyun.com | **~18 MB/s** | Internal Aliyun network = fast |
| registry.cn-shanghai.aliyuncs.com | **Very fast** (0.06s RTT, 401 expected) | ACR within Aliyun network |
| npmmirror.com | **12 KB/s** | Slow external Chinese mirror |
| pypi.org | **10 KB/s** | Very slow international |
| dlcdn.apache.org | **35 KB/s** | Slow international |
| github.com | **~5 KB/s** (timeout at 15s) | Essentially unreachable |
| registry-1.docker.io | **0 bytes** (connection refused) | **Completely blocked** from Aliyun network |

**Key finding**: Aliyun internal services are very fast. International internet is extremely slow or blocked (Docker Hub is fully blocked). This mirrors the known "GFW" / Aliyun network filtering challenges.

---

## 4. Recommended Options (50 CNY Budget)

### Option 1: ACR Personal Edition (Container Registry) -- FREE (RECOMMENDED)

| Detail | Value |
|--------|-------|
| **Cost** | **Free** (public beta, no charge) |
| **Setup time** | Minutes |
| **Impact** | High |
| **Limits** | 3 namespaces, 300 repos, 3 GB per image, no SLA |

**Why**: Docker Hub is completely blocked from Aliyun. ACR within Aliyun network is fast. Personal Edition is free.

**What to do**:
1. Create ACR Personal Edition in cn-shanghai
2. Mirror common kyb base images (ubuntu:noble, node, python, etc.) via ACR's automated image sync from Docker Hub
3. Update kyb build to pull from `registry.cn-shanghai.aliyuncs.com/kyb/...` instead of Docker Hub
4. For images that can't be synced, pull through the kyb-infra-sing-box proxy and push to ACR

**Note**: ACR Personal Edition image sync pulls from Docker Hub via Aliyun's backend, which may bypass the Docker Hub block. Test this first.

---

### Option 2: Use Sim as Selective HTTP Proxy -- FREE

**Cost**: Free (already running)

**How**:
1. Set up a simple HTTP proxy on sim (squid/nginx/3proxy)
2. Route only Aliyun-internal traffic (mirrors.aliyun.com, ACR, OSS) through sim
3. Keep international traffic going through the existing kyb-infra-sing-box (Relay-JP2 shadowsocks)

**Why useful**: kyb containers are on macOS/OrbStack. Their access to `mirrors.aliyun.com` goes through the macOS internet, which may be slower than going via sim's fast Aliyun internal network.

**Caveat**: The 3 Mbps EIP bottleneck means sim cannot be a general-purpose proxy for international traffic. It would be WORSE than the current kyb-infra-sing-box proxy for non-Aliyun endpoints.

---

### Option 3: Aliyun OSS for Build Artifact Cache -- Very Low Cost

**Cost**: ~0.12 CNY/GB/month for storage, ~0.5 CNY/GB for outbound traffic

**Use case**: Cache mise tool downloads (Node, Python, Ruby, glab, etc.) in an OSS bucket. Since these downloads go through the 3 Mbps EIP anyway, OSS within Aliyun network would be much faster.

**How**:
1. Create OSS bucket in cn-shanghai
2. Pre-populate with mise tool tarballs (node, python, ruby, maven, glab, clickhouse, claude-code)
3. Point kyb build to pull from OSS instead of the original URLs
4. Downloads would go through Aliyun internal network (~18 MB/s) instead of international (~5-35 KB/s)

**Cost estimate**: ~200GB bandwidth cache, minimal storage. Probably < 1 CNY/month.

---

### Option 4: DDH / Dedicated Proxy on Sim -- Low Cost

**Cost**: Free (sim already running)

**What**: Deploy a transparent proxy/cache (squid with cache_peer, nginx proxy_cache, or varnish) on sim specifically for:
- Docker image layers (via ACR or direct)
- npm/pip/gem packages
- mise tool downloads

**Why**: Multiple kyb containers fetching the same npm/pip packages can hit a local cache on sim. First fetch is slow (through sim's 3 Mbps), subsequent fetches are instant.

---

### Option 5: Use Aliyun CDN for Public Mirror -- Low Cost

**Cost**: CDN HTTPS traffic ~0.24 CNY/GB (China mainland), or use overseas CDN for cheaper

**What**: Set up a custom CDN domain that proxies to GitHub releases or other blocked sites. Aliyun CDN nodes within China may have different routing.

**Caveat**: CDN for foreign sites may be blocked by GFW or Aliyun policies. Needs testing.

---

### Options NOT Feasible with 50 CNY Budget

| Option | Monthly Cost | Why Not Feasible |
|--------|-------------|------------------|
| NAT Gateway | ~177 CNY/month | Instance fee alone > budget |
| SAE (minimal) | ~50-100 CNY/month | Even 0.5C1G instance over budget |
| EIP Bandwidth Upgrade | Not available | 99 plan bandwidth is fixed at 3 Mbps |
| CEN (Cloud Enterprise Network) | High | Enterprise-level pricing |
| Dedicated Line / VPN | High | >1000 CNY/month |

---

## 5. Cost Estimates Summary

| # | Option | First Month | Setup Time | Maintain | Risk |
|---|--------|-----------|------------|----------|------|
| 1 | ACR Personal Edition | **0 CNY** | 10 min | 0 CNY/month | Docker Hub sync may not work |
| 2 | Sim as HTTP proxy | **0 CNY** | 15 min | 0 CNY/month | Limited benefit |
| 3 | OSS artifact cache | **<1 CNY** | 30 min + fill cache | <1 CNY/month | Manual cache filling |
| 4 | Squid cache on sim | **0 CNY** | 20 min | 0 CNY/month | Only helps repeated downloads |
| 5 | Aliyun CDN proxy | **~5-25 CNY** | 1 hour | variable | GFW compliance risk |
| - | NAT Gateway | 177+ CNY | 30 min | 177+ CNY/month | Over budget |
| - | SAE deploy | 50+ CNY | 1 hour | 50+ CNY/month | Over budget |
| - | EIP upgrade | N/A | N/A | N/A | Not available on 99 plan |

---

## 6. Quickest Win (Minutes vs Days)

### Minutes (0-30 min, free):
1. **Register ACR Personal Edition** -- 10 min, free
   - Open Aliyun console, create ACR personal instance in cn-shanghai
   - Get the registry address: `registry.cn-shanghai.aliyuncs.com`

2. **Install aliyun CLI on sim** -- 5 min
   - `sudo pip3 install aliyun-cli` (or download the binary)
   - Configure with Aliyun AccessKey (need to create one from console)

3. **Audit sim's current resources** -- 10 min
   - `aliyun ecs DescribeInstances --region cn-shanghai`
   - Check EIP, bandwidth packages, security groups

### Hours (1-4 hours, free to minimal cost):
4. **Set up ACR image sync for kyb base images** -- 2 hours
   - Sync ubuntu:noble, node:25, python:3.10, ruby:3.3 from Docker Hub to ACR
   - Modify Dockerfile to pull from ACR instead of Docker Hub
   - Test `kyb build`

5. **Set up OSS + mise tool mirror** -- 3 hours
   - Create OSS bucket
   - Download mise tool tarballs through proxy, upload to OSS
   - Modify Dockerfile mise install to use OSS URLs
   - Rebuild and test

### Days (requires Aliyun console access, account setup):
6. **Create Aliyun AccessKey** for CLI automation
7. **Set up Aliyun RAM user** with minimal permissions for CI/CD
8. **Test ACR image sync** reliability across different Docker Hub images
9. **Consider SAE** as a deployment target for lightweight services (if >50 CNY budget available later)

---

## Key Findings Summary

1. **Docker Hub is completely blocked from Aliyun ECS** direct connections. Must use proxy (kyb-infra-sing-box Relay-JP2) or ACR mirroring.

2. **Aliyun internal services are fast** (18 MB/s to mirrors, instantaneous to ACR). The bottleneck is exclusively **internet egress through the 3 Mbps EIP**.

3. **50 CNY credit covers 6 months of low-cost services** (ACR + OSS + CDN) but not enough for NAT Gateway or SAE.

4. **The kyb-infra-sing-box shadowscoks relay is essential** for international traffic from sim. Without it, sim can't reach Docker Hub, GitHub, or npm.

5. **Quickest wins are ACR registrations and aliyun CLI setup** (minutes, free). Most impactful is ACR image mirroring for kyb Docker builds.

6. **The click-rest bin/sae file is not accessible** -- needs repo access grant to evaluate SAE deployment patterns.
