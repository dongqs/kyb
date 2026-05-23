# kyb-infra-boss Session Handoff Template

> **Session:** YYYY-MM-DD HH:MM CST -- YYYY-MM-DD HH:MM CST
> **To:** Next kyb-infra-boss session
> **Goal:** Productive within 5 minutes of reading this.

---

## 1. Current Infrastructure State

**N containers running**, all on `kyb-net`:

| Container | Port(s) | Status | Uptime | Notes |
|-----------|---------|--------|--------|-------|
| kyb-infra-sing-box | 2080 (SOCKS5+HTTP) | | | restart:always |
| kyb-infra-redis | 6379 | | | |
| kyb-infra-kafka | 9092 (KRaft) | | | |
| kyb-infra-postgresql-XX | XXXX | | | |
| kyb-infra-clickhouse | 8123/9000 | | | |
| kyb-infra-grafana | 3000 | | | |
| kyb-infra-cc-connect | 9111/9810/9820 | | | |
| kyb-registry-cache | 5002 (host net) | | | |
| kyb-infra-boss | -- | | | |
| kyb-infra-... | | | | |

**System resources:**
- RAM: XG used / XG total
- Swap: XG used / XG
- Zombie processes: ~N
- Disk: XG/XXXG (XX%)
- Docker build cache: XG reclaimable

**Docker containers list:**
```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}'
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
docker ps -a --filter status=exited --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
```

---

## 2. What Was Done This Session

### 2.1 Key Achievements

1. 
2. 
3. 

### 2.2 Infrastructure Changes

| Service | Action | Details |
|---------|--------|---------|
| | | |

### 2.3 Commits / MRs

| Commit/MR | Description |
|-----------|-------------|
| | |

### 2.4 Network Topology (if changed)

```
Current topology:
```

---

## 3. Key Credentials (Where to Find)

| Credential | Location | Notes |
|------------|----------|-------|
| Feishu app_id / app_secret | `.env.kyb` | |
| ACR registry | `.env.kyb` | |
| OSS keys | `.env.kyb` | |
| Feishu/DingTalk Webhook | `.env.kyb` / `bin/notify-im` | |
| Anthropic API key | `~/.claude/settings.json` | |
| Other | | |

---

## 4. Known Issues

### 4.1 Active Blockers

| # | Issue | Impact | Workaround | Status |
|---|-------|--------|------------|--------|
| 1 | | | | |
| 2 | | | | |

### 4.2 Orphan / Idle Containers

| Container | State | Assessment | Action |
|-----------|-------|------------|--------|
| | | | |

### 4.3 Non-Blocking Issues

| # | Issue | Details | Status |
|---|-------|---------|--------|
| 1 | | | |

### 4.4 Container Rebuild Checklist

Things lost on rebuild that need manual reinstall:

**In kyb-infra-boss container — lost on rebuild:**
1. **mise toolchains** — `mise install`
2. **Global npm packages** to reinstall:
   - `npm install -g @anthropic-ai/claude-code`
   - `npm install -g @larksuite/cli`
   - `npm install -g imcc puppeteer yarn`
3. **Python packages** to reinstall:
   - `pip install mig25 mig25_codegen pgcli fastapi uvicorn playwright pydantic pydantic-settings SQLAlchemy`
4. **uv tools** to reinstall:
   - `curl -LsSf https://astral.sh/uv/install.sh | sh`
   - `uv tool install kimi-cli`
5. **Shell aliases** to add to `~/.bashrc`:
   - `alias claude='claude --dangerously-skip-permissions'`
   - `alias fd=fdfind`
   - `eval "$($HOME/.local/bin/mise activate bash)"`
6. **~/bin/ symlinks** to recreate:
   - `ln -s ~/.local/share/mise/installs/npm-anthropic-ai-claude-code/latest/bin/claude ~/bin/claude`
   - `ln -s /home/dev/.kyb/bin/kyb ~/bin/kyb`
   - `ln -s ~/.local/share/uv/tools/kimi-cli/bin/kimi-cli ~/bin/kimi-cli`

---

## 5. Next Steps

### Priority 1: Stabilize Running Services

- [ ] 
- [ ] 
- [ ] 

### Priority 2: Observability

- [ ] 
- [ ] 

### Priority 3: Project Onboarding

- [ ] 
- [ ] 

### Priority 4: Infrastructure Gaps

- [ ] 
- [ ] 

---

## 6. Quick Reference

### 6.1 Essential Commands

```bash
# List infra containers with status
docker ps --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}'

# Check resource usage
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
free -h | head -2
uptime

# Send IM notification (Feishu + DingTalk)
/home/dev/projects/kyb/bin/notify-im "message here"

# Grafana
open http://localhost:3000

# ClickHouse query
clickhouse-client --host host.orb.internal --query "SELECT version()"

# PostgreSQL
psql postgresql://postgres:postgres@127.0.0.1:5432/postgres
```

### 6.2 Key File Paths

| Path | Purpose |
|------|---------|
| `/home/dev/projects/kyb/docs/infra/` | All infra docs |
| `/home/dev/projects/kyb/docs/infra/handbook/` | Deployment handbooks |
| `/home/dev/projects/kyb/.env.kyb` | Credentials |
| `/home/dev/projects/kyb/bin/notify-im` | IM notification script |
| `/home/dev/.config/sing-box/config.json` | Sing-box proxy config |
| `~/.config/kyb/config.yml` | User's kyb project config |

### 6.3 GitLab Issues Reference

| Issue | Title | Status |
|-------|-------|--------|
| | | |

### 6.4 Document Dependencies

```
handbook/postgresql-deploy.md  ← PG containers
handbook/redis-deploy.md       ← Redis container
handbook/kafka-deploy.md       ← Kafka KRaft container
handbook/clickhouse-deploy.md  ← ClickHouse container
handbook/grafana-deploy.md     ← Grafana + dashboards
handbook/sing-box-deploy.md    ← Proxy + nuc8 tunnel
handbook/registry-cache-deploy.md ← Docker pull-through cache
handbook/acr-deploy.md         ← ACR registry integration
handbook/cc-connect-deploy.md  ← cc-connect Feishu bridge
handbook/hooks-ck-pipeline.md  ← Claude hooks -> CK pipeline
handbook/nuc8-tunnel-deploy.md ← nuc8 SSH tunnel
chat.md                        ← Feishu/DingTalk troubleshooting
```

---

## 7. Boss Mode Reminder

- **Dispatch, don't do** -- you're the boss, not the worker
- **Never wait** -- anything blocking >1s gets dispatched
- **Agents lie** -- verify everything
- **Cross-review** -- implementer and reviewer must be separate agents
- **File conflict groups** -- don't let agents touch same files simultaneously
- **Context limits** -- batch agents per wave
- **Parallel by default** -- dispatch, monitor, collect

---

> Written for next kyb-infra-boss session.
> 
> ／人◕ ‿‿ ◕人＼
