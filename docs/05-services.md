# Services Layer — boss-12 (192.168.215.12)

## Running Services

| Service | Port | Status | Notes |
|---------|------|--------|-------|
| SSH (OpenSSH) | 22/tcp | Running | Only listening service |

No other services are currently running on this container.

## Client Tools (Can Connect To External Services)

| Tool | Purpose | Target |
|------|---------|--------|
| `psql` (PostgreSQL 16) | Database client | External PostgreSQL |
| `clickhouse-client` (26.4) | Database client | ClickHouse on host: `host.orb.internal:9000` |
| `glab` (1.92.1) | GitLab CLI | `git.leyantech.com` |
| `docker` (29.1.3) | Container client | External Docker daemon |

## Key Observations

- **Docker daemon is NOT accessible** from inside this container (`/var/run/docker.sock` not mounted). This is expected for a boss container — it manages sandboxes by SSH-ing into them, not by directly controlling Docker.
- **No local databases** (no PostgreSQL or ClickHouse server processes running).
- **No web servers** (nginx, Apache, etc.).
- **No monitoring agents** installed.

## Boss Container Role

Based on the environment, this container acts as a **boss/manager** for kyb sandboxes:

| Indicator | Evidence |
|-----------|----------|
| No Docker socket | `/var/run/docker.sock` not mounted |
| ~/.claude is a git repo | Contains agent workflow instructions |
| Full mise toolchain | Ruby, Node, Python, glab for orchestration |
| SSH access | Used to connect to and manage other containers |
| No projects | `~/projects/` is empty — work is done in other containers |
