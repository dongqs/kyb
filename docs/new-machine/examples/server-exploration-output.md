# Server: 192.168.215.17

**Hostname**: ac574cdaa405 (container ID)
**Provisioned**: 2026-05-20
**Status**: active, fresh (no projects deployed)
**Type**: kyb sandbox container (Docker on OrbStack)

---

## Physical / Host

| Item | Value |
|------|-------|
| Architecture | aarch64 (ARM64) |
| CPU | Apple M-series, 10 vCPU @ 2.0 GHz |
| RAM | 15 GiB |
| Swap | 16 GiB (zram0: 15.7G lz4, /dev/vdc: 1G) |
| Host kernel | 7.0.5-orbstack-00330 (OrbStack) |
| Host platform | Apple Silicon (OrbStack) |
| Uptime | 7 days 22h (boot ~2026-05-13) |

The machine is a **Docker container** on a host running OrbStack. Not bare-metal or VM. Identical kernel and hardware profile to other kyb sandboxes (192.168.215.5, .10, .15).

## OS

| Item | Value |
|------|-------|
| Distribution | Ubuntu 24.04.4 LTS (Noble Numbat) |
| Kernel | Linux aarch64, 7.0.5-orbstack-00330-dirty |
| Timezone | Etc/UTC |
| Locale | C.UTF-8 |
| PID 1 | `sleep infinity` (no systemd) |

### Key APT Packages

- **Docker**: docker.io 29.1.3, containerd 2.2.1, docker-compose-v2 2.40.3, docker-buildx 0.30.1
- **Dev**: build-essential, gcc/g++ 13.3.0, git 2.43.0, curl, wget
- **Tools**: fzf 0.44.1, fd-find 9.0.0, cron, bind9-dnsutils, gnupg 2.4.4
- **Fonts**: wqy-zenhei (中文), noto-color-emoji, ipafont-gothic, freefont, dejavu, unifont

## Storage

| Device | Size | Type | Mount | Usage |
|--------|------|------|-------|-------|
| overlay | 78 GiB | overlayfs | `/` | 53G used / 26G free (67%) |
| /dev/vdb1 | 926 GiB | partition | Docker volume | 78G allocated to container |
| /dev/vdb | 8 TiB | raw disk | - | host-level; 926G partitioned |
| /dev/zram0 | 15.7 GiB | swap (lz4) | [SWAP] | 2.4G used |
| /dev/vdc | 1 GiB | swap | [SWAP] | 0 used |

**Note**: `vdb` is an 8T raw disk with 926G partitioned. Only 78G is exposed to this container via Docker overlay volume. The host has significant additional storage.

## Network

| Item | Value |
|------|-------|
| IP | 192.168.215.17/24 |
| Gateway | 192.168.215.1 |
| Interface | eth0@if1979 (veth pair) |
| MAC | 96:92:92:f0:25:5f |
| DNS | 0.250.250.200 (Docker-generated) |
| Subnet | 192.168.215.0/24 (OrbStack internal) |

**Open ports**: 22 (SSH) only.
**Firewall**: none (iptables installed but no rules configured; ufw not available).
**Proxy**: none configured (`http_proxy`/`https_proxy` not set).
**Tailscale**: not installed.
**External connectivity**: git.leyantech.com reachable (~19ms ping).

Same OrbStack overlay network as other kyb sandboxes.

## Runtime / Toolchain

All managed via **mise** (v2026.5.12 linux-arm64):

| Tool | Version | Via |
|------|---------|-----|
| Node.js | 25.9.0 | mise |
| Ruby | 3.3.11 | mise |
| Python | 3.10.20 | mise (pip 26.1.1) |
| Maven | 3.9.16 | mise (but no Java runtime) |
| glab | 1.92.1 | mise |
| clickhouse-client | 26.4.2.10 | mise |
| claude-code | 2.1.145 | mise (npm) |
| puppeteer | (installed with Node) | npm global via mise |
| yarn | 1.22.22 | via Node |
| npm | 11.12.1 | via Node |
| git | 2.43.0 | APT |
| OpenSSH | 9.6p1 | APT |
| Docker | 29.1.3 (client only) | APT |

### Missing / Notable

| Item | Status |
|------|--------|
| Java | **not installed** (Maven installed but no JDK) |
| Go | **not installed** |
| Docker daemon | **not accessible** (no `/var/run/docker.sock`) |
| Python pip packages | none special (no mig25, fastapi) |

### Docker Status

Docker client is installed but the Docker daemon socket (`/var/run/docker.sock`) is not mounted. No containers or images. This is a sandbox container where Docker commands would proxy to the host daemon if the socket were available, but in this case it is not.

## Services

| Service | Status | Port |
|---------|--------|------|
| SSH (OpenSSH) | Running | 22 |
| Docker daemon | Not available | - |

No other services are running. No PostgreSQL, no ClickHouse server, no web servers.

### SSH Configuration

- PubkeyAuthentication: yes (default)
- PasswordAuthentication: no (KbdInteractiveAuthentication disabled)
- PermitRootLogin: not explicitly set (default: prohibit-password)
- Authorized keys are configured for `dev` user

### Process Tree

```
PID 1 → sleep infinity
  └─ sshd (listener, 0/10-100 startups)
      └─ sshd sessions (many zombie processes from probe sessions)
```

There are multiple zombie `[sshd] <defunct>` processes from repeated SSH probes, but no active user sessions.

## User Accounts

| User | Groups | Sudo | Auth |
|------|--------|------|------|
| dev | dev, sudo | passwordless (sudo -n OK) | SSH key (authorized_keys) |

`dev` is the only user. Docker group exists but `dev` is not a member.

## Projects

None. The `~/projects/` directory is empty. This is a **fresh** sandbox.

## Claude AI Environment

The container has a pre-configured AI agent environment:

| Item | Location |
|------|----------|
| CLAUDE.md | `~/.claude/CLAUDE.md` — structured probe instructions |
| record.sh | `~/.claude/record.sh` — helper for recording layer probes |
| audits/ | `~/.claude/audits/` — probe audit scripts |
| docs/ | `~/.claude/docs/` — per-layer probe output |
| Git repo | `~/.claude/` is a git repo (3 commits: init, record.sh, initial probes) |

A `record.sh` helper script is available for AI agents to systematically probe and document the 5 layers (physical, os, network, runtime, services). Note: the script has a heredoc variable expansion bug that prevents correct command execution.

## Observations

1. **Standard kyb sandbox** — identical image, tooling, and kernel to other sandboxes (192.168.215.5, .10, .15). All are kyb-managed Docker containers on the same OrbStack host.

2. **Fresh state** — no projects, no Docker images/containers, no database services, no crontab entries.

3. **No Docker socket** — unlike some sandboxes, `/var/run/docker.sock` is not mounted. Docker CLI is installed but cannot communicate with a daemon.

4. **No proxy** — unlike the primary kyb container (192.168.215.5) which has `socks5://host.orb.internal:2080`, this container has no proxy environment configured.

5. **No Tailscale** — if cross-network access is needed, Tailscale needs to be installed and configured.

6. **No Java** — Maven 3.9.16 is installed via mise but the Java runtime is missing (no JDK).

7. **Many sshd zombies** — repeated SSH probes left zombie sshd processes. These are harmless but suggest the container's init process (`sleep infinity`) does not reap orphaned children.
