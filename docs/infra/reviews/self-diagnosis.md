---
decision: 现在就做
---

# Emergency Self-Diagnosis Playbook: Infra-Boss

> **Document:** `docs/infra/reviews/self-diagnosis.md`
> **Scope:** What to do when infra-boss itself is broken — when it cannot patrol, dispatch, communicate, or trust its own state.
> **Date:** 2026-05-23
> **Applies to:** All kyb-infra-boss containers across all clusters (super-boss, aliyun-boss, office-boss).

---

## Table of Contents

1. [Symptom Taxonomy](#1-symptom-taxonomy)
2. [Triage Ladder](#2-triage-ladder)
3. [Symptom-Specific Recovery](#3-symptom-specific-recovery)
4. [Full Boss Restart Procedure](#4-full-boss-restart-procedure)
5. [Clustered Failure: Multi-Boss Outage](#5-clustered-failure-multi-boss-outage)
6. [Bare-Metal Recovery (When Boss Cannot Self-Heal)](#6-bare-metal-recovery-when-boss-cannot-self-heal)
7. [Escalation Protocol](#7-escalation-protocol)
8. [Post-Mortem Checklist](#8-post-mortem-checklist)

---

## 1. Symptom Taxonomy

The infra-boss is a Claude Code session running inside a `kyb-infra-boss` container. It can fail in distinct layers. Identify which layer is failing before attempting recovery.

| Layer | Component | Failure Mode | Symptom Keywords | Severity |
|-------|-----------|-------------|------------------|----------|
| **L1** | Container runtime | Boss container stopped or crashed | `container not found`, `cannot connect`, `kyb-` prefix missing | P0 — infrastructure down |
| **L2** | Docker socket | Cannot talk to local Docker | `permission denied`, `cannot connect to docker daemon`, `Got permission denied` | P0 — cannot manage containers |
| **L3** | Network / proxy | No internet, no Tailscale, no GitLab | `connection refused`, `timeout`, `Could not resolve`, `proxy connect error` | P1 — limited functionality |
| **L4** | Claude API | Cannot call Claude (no session) | `401`, `403`, `rate limited`, `insufficient_quota`, `api_key not configured` | P1 — cannot think or dispatch |
| **L5** | Filesystem | Disk full or read-only | `No space left on device`, `Read-only file system`, `cannot write` | P1 — data loss risk |
| **L6** | Heartbeat / CK | Cannot write to central ClickHouse | `connection refused :8123`, `curl: (7)`, `curl: (28) timeout` | P2 — observability degraded |
| **L7** | SSH to other clusters | Cannot reach aliyun/office bosses | `ssh: connect to host`, `Permission denied (publickey)`, `port 22: Connection refused` | P2 — cannot dispatch remotely |
| **L8** | Git / push | Cannot commit or push | `Permission denied (publickey)`, `could not read from remote`, `failed to push` | P2 — work will be lost on crash |
| **L9** | Agent itself | Hallucinating, looping, stuck | `I seem to be stuck`, repeating same tool call, not progressing | P2 — boss is sick |

**Before doing anything else**, identify which layer(s) are affected. A single root cause (e.g., "Docker daemon restarted") can manifest as symptoms in multiple layers (L2 + L6 + L7 all fail at once because they all go through Docker networking).

---

## 2. Triage Ladder

Run these checks **in order**. Each step narrows the failure domain. Stop when you find the fault.

### Step 0: Are you the boss?

```bash
# Are you inside a boss container?
hostname | grep -q infra-boss && echo "INSIDE BOSS" || echo "NOT IN BOSS CONTAINER"

# What cluster are you on?
echo "HOST: $(hostname)"
echo "CLUSTER: $(hostname | sed 's/kyb-//; s/infra-//; s/-boss//')"

# Can you see your own PID?
echo "MY PID: $$"
```

If the answer to "are you the boss" is no, you are likely a sandbox or a tool agent. **Stop and escalate** — you should not be running self-diagnosis on infra-boss. A sandbox cannot fix the boss.

### Step 1: Container health

```bash
# Is this container still running? (Check from outside)
# If you can run this, L1 may be fine. If Docker commands fail, L1 is the issue.
docker ps --filter "name=infra-boss" --format '{{.Names}} {{.Status}}' 2>/dev/null
# Expected: "infra-boss Up X minutes" (or "kyb-infra-boss")

# Are there any other boss containers on this host?
docker ps --filter "name=boss" --format '{{.Names}} {{.Status}}'
```

**If this command fails entirely** (cannot connect to Docker): L2 is the issue. Skip to [Symptom L2 recovery](#22-l2-docker-socket-permission-denied-or-daemon-unreachable).

### Step 2: Filesystem

```bash
# Disk usage
echo "DISK: $(df -h / | tail -1 | awk '{print $5 " used of " $2}')"

# Write test
touch /tmp/boss-selfcheck-$$ && echo "WRITE OK" || echo "WRITE FAILED"

# Read test
cat /home/dev/projects/kyb/CLAUDE.md > /dev/null 2>&1 && echo "READ OK" || echo "READ FAILED"

# Git repo integrity
cd /home/dev/projects/kyb && git status --porcelain > /dev/null 2>&1 && echo "GIT OK" || echo "GIT BROKEN"
```

**If disk > 90%**: L5 — skip to [Symptom L5 recovery](#25-l5-disk-full).

**If write test fails**: L5 or the container has lost its volume mounts. **Assume data loss risk and push NOW:**

```bash
cd /home/dev/projects/kyb && git add -A && git commit -m "emergency_save_before_boss_failure" && git push
```

### Step 3: Claude API connectivity

```bash
# Can you think? Test Claude API via the configured key
# (Boss containers use ANTHROPIC_API_KEY from environment)
if [ -n "$ANTHROPIC_API_KEY" ]; then
  echo "API_KEY configured: ${ANTHROPIC_API_KEY:0:8}..."
  curl -s -o /dev/null -w "%{http_code}" \
    https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-sonnet-4-20250514","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}' \
    2>/dev/null && echo " API OK" || echo " API FAILED"
else
  echo "API_KEY NOT CONFIGURED"
fi
```

**If HTTP 401/403**: API key invalid or expired. L4.
**If HTTP 529**: Rate limited. Wait and retry. L4.
**If timeout or connection error**: Network issue, not API. Check L3.
**If no API key at all**: The boss was created without credentials. L4 — needs human intervention.

### Step 4: Network connectivity

```bash
# Proxy check
echo "PROXY: ${ALL_PROXY:-none}"

# Internet check (bypass proxy if set to verify proxy isn't broken)
if [ -n "$ALL_PROXY" ]; then
  # Check with proxy
  curl -s --max-time 5 https://api.ipify.org 2>/dev/null && echo " INTERNET OK (via proxy)" || echo " PROXY BROKEN"
  # Check without proxy
  curl -s --no-proxy --max-time 5 https://api.ipify.org 2>/dev/null && echo " INTERNET OK (direct)" || echo " INTERNET BROKEN (direct)"
else
  curl -s --max-time 5 https://api.ipify.org 2>/dev/null && echo " INTERNET OK" || echo " INTERNET BROKEN"
fi

# GitLab connectivity
curl -s --max-time 5 -o /dev/null -w "%{http_code}" https://git.leyantech.com 2>/dev/null | grep -q '200\|301\|302' && echo " GITLAB OK" || echo " GITLAB BROKEN"

# Tailscale connectivity (to central ClickHouse)
curl -s --max-time 5 http://100.104.244.99:8123/ping 2>/dev/null | grep -q 'Ok.' && echo " CK (TAILSCALE) OK" || echo " CK (TAILSCALE) BROKEN"

# Check sing-box (proxy container)
docker ps --filter "name=sing-box" --format '{{.Names}} {{.Status}}' | grep -q Up && echo " SING-BOX OK" || echo " SING-BOX NOT RUNNING"
```

**If proxy fails but direct works**: The sing-box container or proxy config is broken. L3.
**If direct fails but proxy works**: Outbound directly is blocked (expected in some networks), but proxy is fine. L3 is OK.
**If both fail**: Internet is down. L3.

### Step 5: Heartbeat and CK

```bash
# Can you write to CK?
CK_HOST="${CK_HOST:-http://100.104.244.99:8123}"
curl -s --max-time 5 -X POST "$CK_HOST?query=SELECT+1" 2>/dev/null | grep -q 1 && echo " CK WRITE OK" || echo " CK WRITE FAILED"

# Check your own heartbeat
BOSS_ID=$(hostname)
curl -s --max-time 5 "$CK_HOST?query=SELECT+max(timestamp)+FROM+boss_heartbeats+WHERE+boss_id%3D%27$BOSS_ID%27" 2>/dev/null | grep -q . && echo " HEARTBEAT EXISTS" || echo " NO HEARTBEAT FOUND"

# Check all boss heartbeats
echo "=== ALL BOSS HEARTBEATS ==="
curl -s --max-time 5 "$CK_HOST?query=SELECT+boss_id%2C+max(timestamp)+FROM+boss_heartbeats+GROUP+BY+boss_id+ORDER+BY+max(timestamp)+DESC" 2>/dev/null || echo "CK query failed"
```

**If CK is unreachable**: L6. The boss can still function but cannot report. Document all findings locally and push to git.

### Step 6: SSH to other clusters

```bash
# Check SSH config
echo "SSH CONFIG: $(grep -c 'Host' ~/.ssh/config 2>/dev/null) hosts configured"

# Test SSH multiplexing sockets
ls -la /tmp/ssh-mux-* 2>/dev/null && echo " SSH MUX SOCKETS EXIST" || echo " NO SSH MUX SOCKETS (cold start, first connection will be slow)"

# Ping other bosses (non-blocking, quick test)
for host in sim nuc8; do
  timeout 5 bash -c "echo 'SSH to $host:' && ssh -o ConnectTimeout=3 -o BatchMode=yes $host 'hostname' 2>/dev/null" || echo " SSH to $host FAILED"
done
```

**If SSH to all remote hosts fails**: The network layer is broken, or SSH keys are missing. L3.
**If SSH to a specific host fails**: That host may be down. Check the IP and fallback to public IP.

### Step 7: Git push capability

```bash
# Can you push?
cd /home/dev/projects/kyb
git remote -v
git fetch --dry-run 2>&1 | head -3

# Recent git status (any uncommitted work?)
git status --short | head -10
echo "... total uncommitted: $(git status --short | wc -l) files"
```

**If git push fails**: L8. This means any work you do NOW will be lost if the container restarts. **Push all critical work immediately**, then diagnose.

### Step 8: Self-assessment

Ask yourself (the boss) these questions. Be honest:

1. **Am I thinking clearly?** — Are my responses coherent? Am I repeating myself? Am I stuck in a loop?
2. **Do I trust my tools?** — Did any tool calls return unexpected results (empty output, wrong data, errors)?
3. **Am I seeing hallucinations?** — Did I "find" something that doesn't actually exist when I ran a command?
4. **Am I responding to this playbook?** — Yes = I can still read and follow instructions. No = I am too broken to self-diagnose (bare-metal recovery needed).

If you answer "no" to any of these, you are in an unreliable state. **Switch to escalation protocol immediately.**

---

## 3. Symptom-Specific Recovery

### 3.1 L1: Boss Container Crashed or Stopped

**Symptom:** The boss container is not running. You cannot execute commands inside it.

**Diagnosis (from host):**
```bash
# Check if container exists at all
docker ps -a --filter "name=infra-boss" --format '{{.Names}} {{.Status}} {{.ExitCode}}'

# Check logs for crash reason
docker logs kyb-infra-boss --tail 50
```

**Recovery:**

```bash
# Attempt restart
docker start kyb-infra-boss

# If restart fails, check the exit code and logs
docker logs kyb-infra-boss --tail 100

# Common exit codes:
#   137 = OOM killed — container needed more memory
#   139 = SIGSEGV — something crashed hard inside
#   143 = SIGTERM — manual stop or docker restart
#   1   = init process failed — check entrypoint

# If container was removed (docker rm or kyb rm):
# Recreate the boss
cd /home/dev/projects/kyb  # must be on the host
kyb create infra-boss --extra-mount /var/run/docker.sock:/var/run/docker.sock

# OR if kyb CLI is not available on host:
docker run -d \
  --name kyb-infra-boss \
  --restart unless-stopped \
  --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
  --mount type=bind,source=$HOME/.ssh,target=/home/dev/.ssh \
  --mount type=bind,source=$HOME/.config/kyb,target=/home/dev/.config/kyb \
  --mount type=bind,source=$HOME/.kyb,target=/home/dev/projects/kyb \
  kyb-base:latest \
  /usr/local/bin/kyb-entrypoint.sh
```

**Post-recovery verification:**
```bash
docker exec kyb-infra-boss docker ps
docker exec kyb-infra-boss kyb ps
```

### 3.2 L2: Docker Socket (Permission Denied or Daemon Unreachable)

**Symptom:** `docker ps` returns `Got permission denied` or `Cannot connect to the Docker daemon`.

**Diagnosis:**
```bash
# Check socket existence
ls -la /var/run/docker.sock
# Expected: srw-rw---- or similar. If missing: socket not mounted.

# Check if the host's Docker daemon is running
# (From inside the container, you can't check this directly, so check proxy commands)
curl -s --unix-socket /var/run/docker.sock http://localhost/version 2>/dev/null
```

**Recovery:**

```bash
# If socket exists but permission denied:
# The boss container's user (dev) is not in the docker group.
# Fix by adding the user to the docker group inside the container:
sudo groupadd -g $(stat -c '%g' /var/run/docker.sock) docker 2>/dev/null || true
sudo usermod -aG $(stat -c '%g' /var/run/docker.sock) dev
# Then restart the session (exit and re-enter)

# If socket does not exist:
# The --extra-mount flag was not used when creating the boss.
# This is a critical configuration error. The boss needs to be recreated:
cd /home/dev/projects/kyb
kyb rm infra-boss
kyb create infra-boss --extra-mount /var/run/docker.sock:/var/run/docker.sock

# If OrbStack (macOS): Docker socket may be at /var/run/docker.socket instead
ls -la /var/run/docker.socket 2>/dev/null && \
  ln -sf /var/run/docker.socket /var/run/docker.sock
```

**Critical note:** Without the Docker socket, the boss is **completely non-functional** for managing containers. Fix this before anything else.

### 3.3 L3: Network / Proxy Broken

**Symptom:** `curl` to external services times out or fails. Git operations fail. Heartbeats fail.

**Diagnosis:**
```bash
# Step 1: Is the proxy container running?
docker ps --filter "name=sing-box" --filter "name=proxy" --format '{{.Names}} {{.Status}}'

# Step 2: Can you reach the proxy?
PROXY_HOST="${ALL_PROXY#socks5://}"
PROXY_HOST="${PROXY_HOST%:*}"
curl -s --max-time 5 --proxy "$ALL_PROXY" https://api.ipify.org 2>/dev/null && echo "PROXY OK" || echo "PROXY FAILED"

# Step 3: Is sing-box emitting logs?
docker logs --tail 20 kyb-infra-sing-box 2>/dev/null || docker logs --tail 20 sing-box 2>/dev/null

# Step 4: Check DNS
nslookup git.leyantech.com 2>/dev/null || host git.leyantech.com 2>/dev/null || echo "DNS FAILED"
```

**Recovery:**

```bash
# If proxy container is dead, restart it
docker ps -a --filter "name=sing-box" --format '{{.Names}} {{.Status}}'
docker start kyb-infra-sing-box 2>/dev/null || docker start sing-box 2>/dev/null

# If proxy configuration is wrong, update ALL_PROXY in session
# Check what port sing-box is actually listening on
docker exec kyb-infra-sing-box ss -tlnp 2>/dev/null | grep 2080 || \
  docker exec sing-box ss -tlnp 2>/dev/null | grep 2080

# If sing-box image is missing, rebuild from host
cd /home/dev/projects/kyb/docs/infra/sing-box 2>/dev/null && \
  docker compose up -d 2>/dev/null || \
  echo "Manual sing-box deploy needed"

# Fallback: bypass proxy for critical operations
export NO_PROXY="git.leyantech.com,gitlab.com,github.com,api.anthropic.com,100.104.244.99"
export ALL_PROXY=""     # Disable proxy and go direct (if network allows)

# If direct works but proxy doesn't, you can operate without proxy temporarily
# but push all git work first because the proxy issue means pull/push may fail later
```

**For Tailscale-specific network issues:**

```bash
# Check if Tailscale is reachable at all
ping -c 1 -W 2 100.104.244.99 2>/dev/null || echo "TAILSCALE TO CK FAILED"
ping -c 1 -W 2 100.113.24.32 2>/dev/null || echo "TAILSCALE TO SIM FAILED"

# If Tailscale is down, fall back to public IPs for SSH
# Use alias in ~/.ssh/config to add public IP fallback:
# Host sim
#   HostName 47.100.71.220
#   User dongqs
```

### 3.4 L4: Claude API Broken

**Symptom:** Cannot call Claude API. The boss cannot think, cannot dispatch agents, cannot function.

**Diagnosis:**
```bash
# Check API key
if [ -z "$ANTHROPIC_API_KEY" ]; then
  echo "NO API KEY CONFIGURED"
else
  echo "API KEY: ${ANTHROPIC_API_KEY:0:8}... (length: ${#ANTHROPIC_API_KEY})"
  # Test the key
  response=$(curl -s -w "\n%{http_code}" --max-time 10 \
    https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-sonnet-4-20250514","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}')
  code=$(echo "$response" | tail -1)
  body=$(echo "$response" | head -n -1)
  echo "HTTP $code"
  echo "$body" | head -5
fi
```

**Recovery:**

```bash
# If API key is missing:
# The key is typically in /home/dev/.claude/CLAUDE.md or as environment variable
# Check the environment file
cat /home/dev/projects/kyb/.env 2>/dev/null | grep ANTHROPIC
cat /home/dev/.claude/CLAUDE.md 2>/dev/null | grep api_key

# If key is expired or invalid:
# 1. Check billing: https://console.anthropic.com
# 2. Issue a new key: https://console.anthropic.com/settings/keys
# 3. Update the environment

# If rate limited (HTTP 529):
# Wait 60 seconds and retry.
# Check if org-level rate limit was hit (too many concurrent sessions)
echo "Rate limit hit. Waiting 60s..."
sleep 60

# If quota exhausted:
# This is a billing issue. Cannot be resolved without human intervention.
# ESCALATE to human immediately.
```

**Critical note:** Without Claude API, the boss is **a corpse**. It can read, write files, and run shell commands, but it cannot think or make decisions. **Escalate immediately** if L4 recovery fails.

### 3.5 L5: Disk Full

**Symptom:** `No space left on device`, write operations fail.

**Diagnosis:**
```bash
# Disk usage
df -h /
du -sh /home/dev/projects/kyb/
du -sh /tmp/
du -sh /var/log/

# Find large files
find /home/dev -type f -size +100M -exec ls -lh {} \; 2>/dev/null
find /tmp -type f -size +100M -exec ls -lh {} \; 2>/dev/null
find /var/log -type f -size +50M -exec ls -lh {} \; 2>/dev/null

# Docker disk usage (if Docker socket works)
docker system df 2>/dev/null
```

**Recovery (in order of safety, least destructive first):**

```bash
# Step 1: Clean Docker artifacts (this is usually the biggest win)
docker system prune -f --volumes 2>/dev/null
docker builder prune -f 2>/dev/null

# Step 2: Clean package manager cache
sudo apt-get clean 2>/dev/null
sudo pacman -Scc --noconfirm 2>/dev/null || true

# Step 3: Clean old logs
sudo journalctl --vacuum-time=3d 2>/dev/null
sudo find /var/log -name "*.gz" -delete 2>/dev/null
sudo find /var/log -name "*.1" -delete 2>/dev/null

# Step 4: Clean temp files
rm -rf /tmp/* 2>/dev/null

# Step 5: AFTER cleanup, verify space reclaimed
echo "DISK AFTER CLEANUP: $(df -h / | tail -1 | awk '{print $5}')"
```

**If disk is still full after cleanup:**
- The host disk is full, not just the container. SSH to the host and clean there.
- On the host: same Docker prune commands, plus check Orbstack/Docker desktop disk usage.

### 3.6 L6: Heartbeat / ClickHouse Broken

**Symptom:** Cannot write to central ClickHouse. Patrol reports show CK write failures.

**Diagnosis:**
```bash
# Test CK connectivity
curl -s --max-time 5 http://100.104.244.99:8123/ping 2>/dev/null | grep -q 'Ok.' && echo "CK UP" || echo "CK DOWN"

# If Tailscale IP doesn't work, try alternative routes
curl -s --max-time 5 http://host.orb.internal:8123/ping 2>/dev/null | grep -q 'Ok.' && echo "CK VIA HOST.ORB.INTERNAL" || echo "CK VIA HOST.ORB.INTERNAL FAILED"

# Check if CK container is running (from Docker socket)
docker ps --filter "name=clickhouse" --format '{{.Names}} {{.Status}}'

# Check CK container logs
docker logs --tail 20 kyb-infra-clickhouse 2>/dev/null || docker logs --tail 20 clickhouse 2>/dev/null
```

**Recovery:**

```bash
# If CK container is down, restart it
docker restart kyb-infra-clickhouse 2>/dev/null || docker restart clickhouse 2>/dev/null

# If CK is on a different host (e.g., you are aliyun-boss and CK is on mac):
# The connection goes through Tailscale. If Tailscale is down, you cannot write to CK.
# Document patrol findings locally instead:
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) CK UNREACHABLE" >> /tmp/ck-backlog-$(date +%Y%m%d).log

# If CK is up but queries fail, the boss_heartbeats table may have been dropped:
# Recreate from the schema in multi-cluster-boss-architecture.md
```

**Fallback behavior:** If CK is unreachable, the boss should:
1. Write patrol findings to a local fallback file (`/tmp/ck-backlog-*.log`)
2. Keep trying CK every 60s (consistent with heartbeat interval)
3. Report CK failure in the next available notification channel (Feishu, if that works)

### 3.7 L7: SSH to Other Clusters Broken

**Symptom:** `dispatch aliyun ...` or `dispatch office ...` fails.

**Diagnosis:**
```bash
# Test each host
for host in sim nuc8; do
  echo "--- $host ---"
  ssh -o ConnectTimeout=5 -o BatchMode=yes -v $host 'hostname' 2>&1 | tail -5
done

# Check SSH keys
ls -la ~/.ssh/
ssh-add -l 2>/dev/null || echo "No SSH agent running"

# Check known_hosts
ssh-keygen -F 47.100.71.220 2>/dev/null || echo "sim not in known_hosts"
ssh-keygen -F 100.98.29.39 2>/dev/null || echo "nuc8 not in known_hosts"
```

**Recovery:**

```bash
# If host key changed (man-in-the-middle warning):
ssh-keygen -R 47.100.71.220
ssh -o StrictHostKeyChecking=accept-new dongqs@47.100.71.220 'hostname'

# If connection times out:
# Check if the host is reachable at all
echo "Trying direct (public IP)..."
timeout 5 bash -c "echo > /dev/tcp/47.100.71.220/22" 2>/dev/null && echo "PORT 22 OPEN" || echo "PORT 22 CLOSED"

echo "Trying via Tailscale..."
timeout 5 bash -c "echo > /dev/tcp/100.113.24.32/22" 2>/dev/null && echo "TAILSCALE 22 OPEN" || echo "TAILSCALE 22 CLOSED"

# If only one route works, update ~/.ssh/config to use the working route
# If neither works, the target host may be down (power, network, OS crash)
# Escalate to human — this requires physical access or cloud console

# If SSH key auth fails:
# The mounted ~/.ssh might be incomplete. Check if the private key exists.
ls -la ~/.ssh/id_ed25519 ~/.ssh/id_rsa 2>/dev/null || echo "NO PRIVATE KEY FOUND"
```

### 3.8 L8: Git Push Broken

**Symptom:** `git push` fails with authentication or connectivity errors.

**Diagnosis:**
```bash
# Test connection
ssh -T git@git.leyantech.com 2>&1
# Expected: "Welcome to GitLab, @username!"

# Test remote
cd /home/dev/projects/kyb
git remote -v
git fetch --dry-run 2>&1

# Check SSH agent
ssh-add -l 2>/dev/null || echo "NO SSH KEY LOADED"

# Check deploy key
cat ~/.ssh/id_ed25519.pub 2>/dev/null
```

**Recovery:**

```bash
# If SSH key not loaded:
eval $(ssh-agent -s) && ssh-add ~/.ssh/id_ed25519 2>/dev/null

# If host key changed:
ssh-keygen -R git.leyantech.com
ssh -o StrictHostKeyChecking=accept-new git@git.leyantech.com

# If GitLab is unreachable but internet works:
# GitLab may be down. Try again in 5 minutes.
# For now, save work locally and keep trying.

# If the mounted .ssh directory is empty or wrong:
# The boss was created without SSH key mounting.
# Work needs to be pushed or it will be lost on container restart.
# Emergency save:
cd /home/dev/projects/kyb
git add -A && git commit -m "emergency_save_$(date +%Y%m%d_%H%M%S)"
# Then fix SSH and push, or use HTTP remote:
git remote add emergency https://oauth2:TOKEN@git.leyantech.com/quick-n-dirty/kyb.git
git push emergency HEAD:emergency-save-$(date +%Y%m%d)
```

### 3.9 L9: Agent Hallucinating or Stuck

**Symptom:** The boss is running but producing nonsensical output, repeating the same actions, or stuck in a loop.

**Diagnosis (meta-cognitive check):**

Ask yourself:
1. "What was the last thing I did that produced a correct, verifiable result?"
2. "Have I re-read the same file multiple times without progress?"
3. "Am I proposing to `chmod 777` or similar destructive commands without understanding why?"
4. "Did I run a command and see output that doesn't match reality?"
5. "Have I been staring at the same error message for more than 60 seconds?"

If yes to any of these, you are in a stuck state.

**Recovery (progressive):**

```bash
# Step 1: Ground truth — run a few objective checks
date -u
hostname
pwd
docker ps --format '{{.Names}}' | head -5
# If these return reasonable data, the environment is OK and the issue is cognitive.

# Step 2: Read this playbook again from the top.
# Step 3: If still stuck, DO NOT make any changes. Document the state and escalate.
```

**Ground-truth commands for reality-checking hallucinations:**

| Claim | Verify With |
|-------|-------------|
| "The container is running" | `docker ps --filter name=infra-boss --format '{{.Status}}'` |
| "The file exists" | `ls -la /home/dev/projects/kyb/docs/infra/reviews/self-diagnosis.md` |
| "I pushed successfully" | `git log --oneline -3 origin/HEAD` |
| "The proxy is configured" | `echo $ALL_PROXY` |
| "APIs are reachable" | `curl -s --max-time 5 https://api.anthropic.com/v1/messages -H "x-api-key: test" -o /dev/null -w "%{http_code}"` |

**If recovery fails:** You cannot trust your own output. **STOP ALL ACTIONS.** Escalate to human with a full state dump (see Section 7).

---

## 4. Full Boss Restart Procedure

Use this when:
- Multiple layers are failing simultaneously
- A single fix is not enough
- The boss is behaving erratically and you need a clean slate

### 4.1 Graceful Restart (Planned)

```bash
# Step 1: Push all work
cd /home/dev/projects/kyb
git add -A && git commit -m "pre_restart_save_$(date +%Y%m%d_%H%M%S)" && git push

# Step 2: Stop the heartbeat loop
pkill -f "heartbeat" 2>/dev/null || true
pkill -f "while.*true.*curl.*8123" 2>/dev/null || true

# Step 3: Document restart reason
echo "$(date -u) Boss restart triggered. Reason: $1" >> /tmp/boss-restart-log.txt

# Step 4: Stop the container (this kills the current session)
# NOTE: Running this will terminate your session. Save everything first.
sudo poweroff || exit 0

# After restart, the container's entrypoint will bring everything back up.
# The heartbeat loop will restart.
# The previous session's work is preserved if it was committed and pushed.
```

### 4.2 Hard Restart (Container is Unresponsive)

```bash
# From the HOST (not from inside the boss):
docker kill kyb-infra-boss
docker rm kyb-infra-boss
cd /home/dev/projects/kyb
kyb create infra-boss --extra-mount /var/run/docker.sock:/var/run/docker.sock

# OR if the host doesn't have kyb CLI:
docker run -d \
  --name kyb-infra-boss \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $HOME/.ssh:/home/dev/.ssh \
  -v $HOME/.config/kyb:/home/dev/.config/kyb \
  -v $HOME/.kyb:/home/dev/projects/kyb \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  kyb-base:latest
```

### 4.3 Restart Verification Checklist

After restart, verify all layers sequentially:

```
[*] L1: Container running          — docker ps | grep infra-boss
[*] L2: Docker socket works        — docker exec kyb-infra-boss docker ps
[*] L3: Network/proxy works        — docker exec kyb-infra-boss curl -s https://git.leyantech.com
[*] L4: Claude API works           — (tested by the first tool call)
[*] L5: Disk healthy               — docker exec kyb-infra-boss df -h /
[*] L6: Heartbeat running          — docker exec kyb-infra-boss pgrep -f "heartbeat\|8123"
[*] L7: SSH to other bosses works  — docker exec kyb-infra-boss ssh sim hostname
[*] L8: Git push works             — docker exec kyb-infra-boss bash -c "cd ~/projects/kyb && git push --dry-run"
[*] L9: Self-diagnosis complete    — Can read and respond to this check
```

---

## 5. Clustered Failure: Multi-Boss Outage

If multiple bosses are down simultaneously, the failure is likely at a shared dependency, not individual bosses.

### 5.1 Common-Cause Matrix

| Pattern | Likely Root Cause | Evidence |
|---------|------------------|----------|
| All bosses lose CK connectivity | Tailscale down or central CK host (mac) offline | All heartbeats stop at the same time |
| All bosses lose Docker socket | Shared Docker daemon failure (unlikely in multi-host) | All L2 failures simultaneously |
| All bosses lose Claude API | API key invalid, quota exhausted, Anthropic outage | All L4 failures at once |
| Single boss loses everything | Host machine failure (power, network, disk) | Only one boss affected |
| Cross-cluster SSH fails in both directions | Network partition (Tailscale relay down, cloud network issue) | `dispatch` fails both ways |

### 5.2 Central CK (Mac/Orbstack) Failure

The central ClickHouse runs on Mac/Orbstack. If it goes down:

1. **All bosses lose observability** — no heartbeats, no patrol log, no decision log.
2. **Bosses continue to function autonomously** — but they cannot report.
3. **Recovery is manual** — requires human at the Mac to check Docker, restart CK.

**Boss behavior during CK outage:**
- Continue patrol cycles locally
- Write findings to local fallback (`/tmp/ck-backlog-*.log`)
- Attempt CK reconnect every 60s
- If Feishu works, send a one-time notification about CK being down
- Do NOT escalate to human for CK alone unless it exceeds 30 minutes

### 5.3 Anthropic API Outage

If the Claude API is down globally:

1. **All bosses go silent** — no agent can think or dispatch.
2. **Containers continue running** — Docker is unaffected.
3. **Recovery is impossible without human** — no boss can fix itself without API access.
4. **Escalate immediately** — this is a P0.

**Last-resort message to human (write to a file the human might see):**
```bash
echo "EMERGENCY: Claude API unavailable since $(date -u).
All infra-boss agents are non-functional.
Manual intervention required:
1. Check https://status.anthropic.com
2. Check billing at https://console.anthropic.com
3. If API is back, restart the boss container(s).
4. If long outage, consider failover to alternate AI provider." \
> /home/dev/projects/kyb/EMERGENCY_API_DOWN.md
git add -A && git commit -m "emergency: api outage notification" && git push
```

---

## 6. Bare-Metal Recovery (When Boss Cannot Self-Heal)

When the boss is completely non-functional:
- Container won't start
- Filesystem is corrupted
- Cannot execute any commands
- Agent is hallucinating uncontrollably

### 6.1 When to Go Bare-Metal

The boss should attempt bare-metal recovery when:

1. **Triage ladder** fails at Step 0 (not inside boss container)
2. **Multi-layer failure** affects L1+L2+L3 simultaneously (likely host-level issue)
3. **Agent self-assessment** fails (cannot trust own output)
4. **Escalation timer** expires (30 minutes without progress)

### 6.2 SSH from a Different Box

If the boss is on a remote host and the current session cannot reach it:

```bash
# From Mac/Orbstack (super-boss):
# SSH to the host directly
ssh dongqs@47.100.71.220   # Aliyun sim
ssh dongqs@100.98.29.39    # Office nuc8

# Once on the host:
docker ps -a --filter "name=boss" --format '{{.Names}} {{.Status}} {{.ExitCode}}'
docker logs --tail 50 kyb-infra-boss
```

### 6.3 Emergency Data Recovery

If the host is still running but the boss container is gone:

```bash
# Check if the kyb code volume still exists
ls -la /home/dongqs/.kyb/

# Check git log for last committed work
cd /home/dongqs/.kyb && git log --oneline -5

# Check for uncommitted work (may be lost)
git status --short

# If data volumes are intact, create a fresh boss:
cd /home/dongqs/.kyb && kyb create infra-boss --extra-mount /var/run/docker.sock:/var/run/docker.sock

# If kyb CLI is missing:
# A) Reinstall: git clone git@git.leyantech.com:quick-n-dirty/kyb.git ~/.kyb
# B) Or use docker run directly (see section 4.2)
```

### 6.4 Host-Level Diagnostics

When the host itself is suspect:

```bash
# Resource check
echo "=== HOST ==="
hostname
uptime
echo "MEMORY: $(free -h | grep Mem | awk '{print $3 "/" $2}')"
echo "DISK: $(df -h / | tail -1 | awk '{print $3 " / " $2 " (" $5 ")"}')"
echo "LOAD: $(cat /proc/loadavg)"
echo "DOCKER:"
docker info --format '{{.ServerVersion}}' 2>/dev/null || echo "Docker not running"

# Process check
ps aux | grep -c claude
ss -tlnp | grep -E '8123|2080|22'

# Tailscale
tailscale status 2>/dev/null || echo "Tailscale not running"
```

---

## 7. Escalation Protocol

### 7.1 Escalation Triggers

| Condition | Escalate When | To Whom | Method |
|-----------|--------------|---------|--------|
| Claude API unreachable | Immediately | Human (dongqs) | Emergency file + Feishu |
| Disk full and cleanup failed | After cleanup attempt | Human | Feishu notification |
| Boss container won't start | After 3 restart attempts | Human | Emergency markdown file |
| Multi-boss outage | After confirming pattern | Human | Feishu + file |
| Agent hallucinating | Immediately on detection | Human | Feishu |
| No progress for 30 minutes | After 30 min stuck | Human | Feishu + diary |
| SSH keys missing | Immediately | Human | Feishu |
| CK down > 30 min | After 30 min | Human | Feishu (FYI only) |

### 7.2 Escalation Methods

**Method 1: Feishu notification (preferred)**
```bash
# Send Feishu notification to kyb-kindergarden group
FEISHU_WEBHOOK_URL="https://open.feishu.cn/open-apis/bot/v2/hook/xxx"
curl -s -X POST "$FEISHU_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "msg_type": "interactive",
    "card": {
      "header": {
        "title": {"tag": "plain_text", "content": "⚠️ INFRA-BOSS EMERGENCY"},
        "template": "red"
      },
      "elements": [
        {"tag": "div", "text": {"tag": "lark_md",
          "content": "**Boss**: '"$(hostname)"'\n**Cluster**: '"$(hostname | sed 's/kyb-//; s/infra-//; s/-boss//')"'\n**Issue**: <description>\n**Layer**: L1-L9\n**Time**: '"$(date -u)"'\n**Action Needed**: <what human should do>"
        }},
        {"tag": "action", "actions": [
          {"tag": "button", "text": {"tag": "plain_text", "content": "SSH to host"}, "url": "ssh://..."}
        ]}
      ]
    }
  }'
```

**Method 2: Emergency markdown file (reliable, persists in git)**
```bash
cat > /home/dev/projects/kyb/EMERGENCY.md << 'EMERGENCY_EOF'
# INFRA-BOSS EMERGENCY

**Timestamp:** $(date -u)
**Boss:** $(hostname)
**Cluster:** $(hostname | sed 's/kyb-//; s/infra-//; s/-boss//')
**Symptom:** <brief description>

## State Dump

$(echo "=== DOCKER ===" && docker ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null || echo "DOCKER FAILED")
$(echo "=== DISK ===" && df -h / 2>/dev/null || echo "DISK FAILED")
$(echo "=== NETWORK ===" && curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "NETWORK FAILED")
$(echo "=== HEARTBEAT ===" && curl -s --max-time 5 http://100.104.244.99:8123/ping 2>/dev/null || echo "CK FAILED")
$(echo "=== GIT ===" && cd /home/dev/projects/kyb && git log --oneline -3 2>/dev/null || echo "GIT FAILED")

## Recovery Attempts Made

1. <attempt 1>
2. <attempt 2>

## Next Step Needed

<what the human needs to do>

EMERGENCY_EOF

# Commit and push (if git works; if not, just leave the file on disk)
cd /home/dev/projects/kyb
git add EMERGENCY.md && git commit -m "emergency: boss failure state dump" && git push
```

**Method 3: `kyb notify urgent` (if kyb CLI works)**
```bash
kyb notify urgent "Infra-boss on $(hostname) is broken: L<layer> <symptom>. Need human intervention."
```

### 7.3 State Dump Template

Before escalating, dump the full state so the human has everything they need:

```bash
# Full state dump command (run inside boss)
echo "=== STATE DUMP $(date -u) ==="
echo "BOSS: $(hostname)"
echo "UPTIME: $(uptime)"
echo "---"
echo "DOCKER:"
docker ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null
echo "---"
echo "DISK:"
df -h /
echo "---"
echo "NETWORK:"
curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "NO INTERNET"
echo "---"
echo "CK:"
curl -s --max-time 3 http://100.104.244.99:8123/ping 2>/dev/null || echo "CK UNREACHABLE"
echo "---"
echo "GIT:"
cd /home/dev/projects/kyb && git status --short && git log --oneline -3
echo "---"
echo "PROXY: ${ALL_PROXY:-none}"
echo "API KEY: ${ANTHROPIC_API_KEY:+configured (${#ANTHROPIC_API_KEY} chars)}"
echo "=== END STATE DUMP ==="
```

---

## 8. Post-Mortem Checklist

After any boss failure and recovery, complete this checklist. Write findings to a diary entry.

### 8.1 Root Cause Analysis

```markdown
## Post-Mortem: Boss Failure on <cluster>

**Date:** <date>
**Duration:** <start> → <end> (total <N> minutes)
**Severity:** P<N>
**Layers affected:** L<N>

### What happened?
<description of the failure>

### Root cause
<why it happened>

### Detection
<how the boss detected it (or who detected it if not the boss)>

### Recovery
<what fixed it>

### Timeline
- <time>: <event>
- <time>: <event>
- <time>: <recovery>
```

### 8.2 Prevention Items

- [ ] **Was there a warning sign we missed?** (disk filling, container restarting, latency increasing)
- [ ] **Could self-diagnosis have caught it earlier?** (if yes, update this playbook)
- [ ] **Is there an automated fix?** (if yes, implement it)
- [ ] **Does the playbook need updating?** (any gaps in this document)
- [ ] **Were there data losses?** (uncommitted work, unsaved state)

### 8.3 Playbook Update

If during the incident you found:
- A recovery step that should be added
- A diagnostic check that was missing
- An escalation trigger that was too slow

**Write the update to this playbook and push it.** The next boss failure will benefit.

```bash
cd /home/dev/projects/kyb
# Edit docs/infra/reviews/self-diagnosis.md
git add docs/infra/reviews/self-diagnosis.md
git commit -m "docs: update self-diagnosis playbook after <cluster> incident"
git push
```

---

## Quick Reference Card

### One-Line Per Layer

```
L1 (container)   → docker ps | grep infra-boss
L2 (docker sock) → ls -la /var/run/docker.sock && docker version
L3 (network)     → curl -s --max-time 5 https://api.ipify.org
L4 (claude api)  → env | grep ANTHROPIC_API_KEY
L5 (filesystem)  → df -h /
L6 (ck)          → curl -s http://100.104.244.99:8123/ping
L7 (ssh)         → ssh sim hostname && ssh nuc8 hostname
L8 (git push)    → cd ~/projects/kyb && git push --dry-run
L9 (agent)       → "Can I trust this command's output?" (answer honestly)
```

### Priority Escalation Matrix

```
Immediate escalation (P0):
  └── Claude API down
  └── Multi-boss outage
  └── Agent hallucinating

15-minute escalation:
  └── CK unreachable > 15 min
  └── SSH to a host failed > 15 min
  └── Disk full and cleanup failed

30-minute escalation:
  └── Same patrol finding 6+ cycles in a row
  └── Unable to push git > 30 min
  └── Boss cannot make progress on a task

No escalation (handle locally):
  └── Occasional CK write failure (< 5 min)
  └── Single patrol cycle failure
  └── Brief network interruption
```

### Emergency Commands (Copy-Paste Ready)

```bash
# Test everything at once
echo "L1: $(docker ps --filter name=infra-boss --format '{{.Status}}' 2>/dev/null || echo FAIL)"
echo "L2: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo FAIL)"
echo "L3: $(curl -s --max-time 5 -o /dev/null -w '%{http_code}' https://api.ipify.org 2>/dev/null || echo FAIL)"
echo "L4: $(env | grep -q ANTHROPIC_API_KEY && echo OK || echo FAIL)"
echo "L5: $(df -h / | tail -1 | awk '{print $5}')"
echo "L6: $(curl -s --max-time 5 http://100.104.244.99:8123/ping 2>/dev/null || echo FAIL)"
echo "L7: $(ssh -o ConnectTimeout=3 sim hostname 2>/dev/null || echo FAIL)"
echo "L8: $(cd ~/projects/kyb && git push --dry-run 2>&1 | head -1)"
```

```bash
# Emergency save + push (run when you feel the boss is about to crash)
cd /home/dev/projects/kyb
git add -A
git commit -m "emergency_save_$(date +%Y%m%d_%H%M%S)" 2>/dev/null
git push 2>/dev/null
echo "Emergency save completed at $(date -u)" >> /tmp/emergency-save.log
```

```bash
# Collect full state for escalation
BOSS_STATE="/tmp/boss-state-dump-$(date +%Y%m%d_%H%M%S).txt"
{
  echo "=== STATE DUMP ==="
  echo "TIME: $(date -u)"
  echo "BOSS: $(hostname)"
  echo "=== L1 ===" && docker ps --filter name=infra-boss --format '{{.Status}}' 2>/dev/null
  echo "=== L2 ===" && docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null
  echo "=== L3 ===" && curl -s --max-time 5 https://api.ipify.org 2>/dev/null
  echo "=== L4 ===" && env | grep ANTHROPIC_API_KEY
  echo "=== L5 ===" && df -h /
  echo "=== L6 ===" && curl -s --max-time 5 http://100.104.244.99:8123/ping 2>/dev/null
  echo "=== L7 ===" && ssh -o ConnectTimeout=3 sim hostname 2>/dev/null
  echo "=== L8 ===" && cd ~/projects/kyb && git push --dry-run 2>&1
  echo "=== L9 ===" && echo "Agent self-check: $(curl -s --max-time 5 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/messages -H 'x-api-key: test' 2>/dev/null || echo 'cannot verify')"
} > "$BOSS_STATE"
cat "$BOSS_STATE"
```

---

> **Remember**: You cannot fix the boss if you are the boss and you are broken. The first rule of self-diagnosis is knowing when to stop and escalate.
>
> ／人◕ ‿‿ ◕人＼
