# kyb-infra-boss Session Handoff

> **Session:** 2026-05-22 18:00 CST -- 2026-05-23 08:00 CST
> **Updated by follow-up session:** 2026-05-23 10:38 CST
> **To:** Next kyb-infra-boss session
> **Goal:** Productive within 5 minutes of reading this.

---

## 1. Current Infrastructure State

**15 containers running** (14 documented + kyb-infra-boss2 added later), all on `kyb-net`:

| Container | Port(s) | Status | Uptime | Notes |
|-----------|---------|--------|--------|-------|
| kyb-infra-sing-box | 2080 (SOCKS5+HTTP) | Up | 5h | restart:always |
| kyb-infra-redis | 6379 | Up | 16h | |
| kyb-infra-kafka | 9092 (KRaft) | Up | 16h | |
| kyb-infra-postgresql-14 | 5434 | Up | 16h | |
| kyb-infra-postgresql-15 | 5435 | Up | 16h | |
| kyb-infra-postgresql-16 | 5436 | Up | 16h | |
| kyb-infra-postgresql-17 | 5437 | Up | 16h | |
| kyb-infra-clickhouse | 8123/9000 | Up | 4h | |
| kyb-infra-grafana | 3000 (4 dashboards, 48 panels) | Up | 15h | |
| kyb-infra-cc-connect | 9111/9810/9820 | Up (healthy) | 1h | |
| kyb-registry-cache | 5002 (host net) | Up | 15h | 注意端口是5002不是5000 |
| kyb-infra-boss | -- | Up | 11min | 无--init, 无内存限制, 镜像dangling |
| **kyb-infra-boss2** | -- | Up | 14min | **新增** --init ✅, 4GiB限制, 13.8GB快照镜像 |
| kyb-ubuntu-test | -- | Up | 1h | 网络验证用 |
| bold_almeida | -- | Up (unhealthy) | 3h | 孤儿容器, 待清理 |

**System resources:**
- RAM: 5.2G used / 15G total (10G available)
- Swap: 2.5G used / 16G (zram)
- Zombie processes: ~2（已大幅减少）
- Disk: 70G/304G (23%)
- Docker build cache: 0B（已prune）

---

## 2. What Was Done This Session

### 2.1 Infrastructure Deployments (Wave 0 -- Foundation)

| Service | Config File (handbook) | Notes |
|---------|----------------------|-------|
| PostgreSQL 14/15/16/17 | `handbook/postgresql-deploy.md` | All 4 versions running; trust auth, TZ Asia/Shanghai |
| Redis 7 | `handbook/redis-deploy.md` | AOF enabled, 512MB limit, allkeys-lru |
| Kafka KRaft | `handbook/kafka-deploy.md` | Single-node, 512MB heap |
| ClickHouse | `handbook/clickhouse-deploy.md` | Containerized 24.2-alpine, 4 system DBs, no user data yet |
| Grafana | `handbook/grafana-deploy.md` | 4 dashboards with 48 panels total |
| Sing-box proxy | `handbook/sing-box-deploy.md` | nuc8 tunnel via SSH, SOCKS5+HTTP mixed |
| ACR registry cache | `handbook/acr-deploy.md`, `handbook/registry-cache-deploy.md` | Images found, pulling from `acr-reg:5000` |
| Docker registry cache | `handbook/registry-cache-deploy.md` | `kyb-registry-cache`, pull-through proxy |
| cc-connect | `handbook/cc-connect-deploy.md`, `chat.md` | Feishu bridge deployed, connected, lark-cli MCP ready |
| Claude hooks pipeline | `handbook/hooks-ck-pipeline.md` | 6700+ events emitted to ClickHouse |

### 2.2 Key Achievements

1. **ACR credentials found** in `.env.kyb` -- registry: `crpi-55lo9e6aeed00e4a.cn-shanghai.personal.cr.aliyuncs.com`
2. **Claude hooks pipeline** deployed and working -- 6700+ events in `kyb.claude_hook_events`
3. **cc-connect deployed** with Feishu integration -- container healthy, bot `cli_aa9be3a17d3adbeb` connected via WebSocket
4. **lark-cli MCP** configured for Feishu bot management (event subscription, message sending)
5. **notify-im script** created at `bin/notify-im` -- sends to both Feishu and DingTalk webhooks
6. **All remove_method bugs fixed** in tests (Ruby test suite now clean)
7. **All 20+ infra docs written** in `docs/infra/`:
   - 10 deployment handbooks in `docs/infra/handbook/`
   - 3 survey reports (base-service, oversea-digismart, remaining)
   - Master report, rollout plan, network analysis, cc-connect research
   - Chat integration troubleshooting guide (`chat.md`)

### 2.3 Network Topology

```
macOS Host (Orbstack)
  Docker kyb-net (192.168.97.0/24)
  │
  ├── sing-box (192.168.97.2:2080)
  │   ├── ai-extra (Anthropic) → Relay-US2 (Shadowsocks)
  │   ├── cn-ip (DeepSeek) → Direct
  │   ├── nuc8-proxy (GitLab) → SSH tunnel → sim → Tailscale → nuc8
  │   └── default → Relay-JP2
  │
  ├── PG 14/15/16/17, Redis, Kafka, CK, Grafana
  └── cc-connect (published :9111/:9810/:9820)
```

---

## 3. Key Credentials (Where to Find)

| Credential | Location | Notes |
|------------|----------|-------|
| Feishu app_id / app_secret | `/home/dev/projects/kyb/.env.kyb` | `cli_aa9be3a17d3adbeb` (app_id is in cc-connect config; secret in .env.kyb) |
| ACR registry | `/home/dev/projects/kyb/.env.kyb` | `crpi-55lo9e6aeed00e4a.cn-shanghai.personal.cr.aliyuncs.com`, user/pass in .env |
| OSS keys | `/home/dev/projects/kyb/.env.kyb` | LTAI5t92ApkqbyH4uv6z41KB + secret |
| Feishu Webhook | `/home/dev/projects/kyb/bin/notify-im` (also .env.kyb) | `5b657d80-c050-4965-8e46-9a127a219cf9` |
| DingTalk Webhook | `/home/dev/projects/kyb/bin/notify-im` (also .env.kyb) | `e044c117b1bd5ab5943606d72ea9ef350c72621073b96a983af384e97eb87ec1` |
| Anthropic API key | `~/.claude/settings.json` | For Claude Code |
| GitLab access | via nuc8 tunnel (sing-box -> sim -> nuc8) | No direct access; proxied through nuc8 |
| GitHub PAT | Not stored in repo | Needed for ghcr.io auth (PeerDB etc.) |

---

## 4. Known Issues

### 4.1 Active Blockers

| # | Issue | Impact | Workaround | Status |
|---|-------|--------|------------|--------|
| 1 | **cc-connect lacks `--init` and memory limit** | ~300 zombie processes accumulating; no OOM protection | Restart with `--init` and `--memory` flags | ⏳ 未修复 |
| 2 | **zram swap usage 2.6GB** | Memory pressure under load | Monitor; consider reducing parallel agent count | ⏳ 仍存在 |
| 3 | **PG15/17 images sometimes fail to pull** | Can't recreate these containers from scratch | Images already cached now; but if re-pull needed, may hit mirror rate limits | ⏳ 仍存在 |
| 4 | **Grafana image pull via docker.1ms.run** | Mirror is unofficial; may break | `docker pull grafana/grafana-oss` via ALL_PROXY directly from Docker Hub | ⏳ 仍存在 |
| 5 | **cc-connect bridge stability** | Battle-tested now (~1h healthy) | Monitor logs: `docker logs -f kyb-infra-cc-connect` | ✅ 已稳定 |
| 6 | **lark-cli mcp subcommand** | Not yet available in released binary | Will need to build from source or wait for upstream release | ⏳ 仍存在 |
| 7 | **bold_almeida unhealthy** | Orphan container from earlier test | Clean up: `docker rm -f bold_almeida` | ⏳ 待清理 |
| 8 | **config.yml read-only** | Mounted from host, agents can't register projects | Edit on host, reload in container | ⏳ 仍存在 |
| 9 | **No MySQL container** | ~40 oversea projects blocked | No MySQL deployed yet (major gap) | ⏳ 仍存在 |
| 10 | **nuc8 隧道依赖 boss 容器** | boss 重启后 GitLab 路由中断 | SSH 隧道建在 boss 内, 见 issue #107 | 🔴 新发现 |

### 4.2 Non-Blocking Issues

| # | Issue | Details | Status |
|---|-------|---------|--------|
| 1 | Docker build cache 20G reclaimable | `docker builder prune -a -f` 已执行 | ✅ 已清理 |
| 2 | NO_PROXY not set in entrypoint.sh | CK traffic may route through proxy adding latency | ⏳ 待修复 |
| 3 | ghcr.io not authenticated | PeerDB and other ghcr images blocked | ⏳ 待处理 |
| 4 | ~300 zombie processes (no init in container) | boss2 已加 --init, 原 boss 仍未加 | 部分修复 |
| 5 | nuc8 behind CGNAT | Tailscale relay via sim; no direct P2P | ⏳ 仍存在 |
| 6 | kyb-infra-boss 和 kyb-infra-boss2 同时运行 | 两个 boss 容器指向同一项目目录 | ⚠️ 需决策保留哪个 |
| 7 | registry-cache 文档与实际严重不符 | 容器名、端口、网络模式、代理设置全错 | 🔴 待修文档 |

### 4.3 孤儿容器评估（2026-05-23 更新）

当前系统中存在以下孤儿/闲置容器，均来自上一轮 session 的测试残留。按清理紧迫度排序：

| 容器 | 状态 | 类型 | 评估 | 建议 |
|------|------|------|------|------|
| **bold_almeida** | running, unhealthy, auto-remove | cc-connect 重复实例 | 命令错误（cc-connect sh -c "cat config.toml"），健康检查失败363次，端口未发布，在bridge网络而非kyb-net | `docker stop`（auto-remove会自动清理） |
| **kyb-ubuntu-test** | running, up 1h | 网络连通性验证 | 已验证 kyb-net 通信正常，不再需要 | `docker rm -f` |
| **friendly_banach** | Exited (5) 7h | kyb create 残留 | exit code 5 可能是 entrypoint 执行失败 | `docker rm` |
| **kyb-kyb-robust** | Exited (5) 7h | kyb create 残留 | 同上 | `docker rm` |
| **kyb-test-entrypoint-ghtoken** | Exited (0) 16h | 启动脚本测试 | 正常退出但已无用 | `docker rm` |
| **stoic_feistel** | Created 16h, 从未启动 | docker run 测试 | 未启动过 | `docker rm` |

**清理风险：** 无。这些容器无持久数据、无卷、无端口映射。bold_almeida 设了 auto-remove，stop 即可完全清理。

### 4.4 kyb-infra-boss vs kyb-infra-boss2 双容器问题

当前两个 boss 容器同时运行，指向同一项目目录：

| | kyb-infra-boss | kyb-infra-boss2 |
|---|---|---|
| 创建时间 | 18h 前（session 中） | 14min 前（后续 session） |
| --init | ❌ 无 | ✅ 有 |
| 内存限制 | ❌ 无（15.65G） | ✅ 4GiB |
| 镜像 | kyb-base (7.9G, dangling) | kyb-infra-boss-snapshot:latest (13.8G) |
| 当前会话 | ✅ 有 Claude 会话运行 | ❌ 空闲 |

**决策：** 下轮需决定保留哪个。boss2 配置正确（--init + 4GiB），但快照镜像大 5.9G；boss 有你当前的会话。

### 4.5 Container Rebuild Checklist

Include everything that needs manual reinstall after a container rebuild:

**In the `kyb-infra-boss` container — lost on rebuild, needs manual setup:**

1. **mise toolchains** — `mise install` re-fetches (keep config at `~/.config/mise/config.toml`)
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

Also mention the container launch fixes needed:
- [ ] **Add `--init`** to ALL `docker run` commands
- [ ] **Add `--memory` limits** per container role
- [ ] **kyb-infra-boss image is dangling** — must `kyb build` before recreate
- [ ] **Clean up orphans** after rebuild: `docker rm -f bold_almeida friendly_banach kyb-kyb-robust stoic_feistel kyb-test-entrypoint-ghtoken`

---

## 5. Next Steps

### Priority 1: Stabilize Running Services

- [ ] Restart cc-connect with `--init` and `--memory 512m`
- [ ] Restart kyb-infra-boss with `--init` (fix zombie accumulation)
- [ ] Set memory limits on ALL containers (currently most use 15.65G limit)
- [x] ~Remove orphan containers~ → **已评估，下轮清理**
- [x] ~Run `docker builder prune -a -f`~ → **已清理（0B）**
- [ ] nuc8 隧道持久化（见 issue #107）— 当前依赖 boss 存活
- [ ] 清理 5 个孤儿容器（bold_almeida, kyb-ubuntu-test, friendly_banach, kyb-kyb-robust, kyb-test-entrypoint-ghtoken, stoic_feistel）
- [ ] 决定 kyb-infra-boss vs kyb-infra-boss2 去留

### Priority 2: Complete Observability

- [ ] Verify Claude hooks pipeline is actively emitting events: `SELECT count() FROM kyb.claude_hook_events`
- [ ] Wire Claude hooks configuration into entrypoint.sh (so it persists across restarts)
- [ ] Set up Kafka -> ClickHouse engine tables for event streaming
- [ ] Verify all 4 Grafana dashboards render data (currently 48 panels total)

### Priority 3: Start Wave 3 Project Onboarding

- [ ] Onboard digismart batch 1 (6 projects: robot-processor, invoice-robot-cloud, dgt-risk-control, dgt-bi-server, digismart-alipay, digismart-item)
- [ ] Onboard digismart batch 2 (6 projects: theia, mola-service, robot-transfer, robot-types, digsmart-metabase, llm-wiki)
- [ ] See `docs/infra/100-project-rollout-plan.md` for full wave breakdown

### Priority 4: Infrastructure Gaps

- [ ] Deploy MySQL 8.0 container (needed by ~40 oversea projects)
- [ ] Authenticate to ghcr.io with GitHub PAT (unblock PeerDB)
- [ ] Configure pgvector on PG15 (for assistant, bot-trainer)
- [ ] Add NO_PROXY to entrypoint.sh (`NO_PROXY="host.orb.internal,kyb-infra-*,localhost,127.0.0.1"`)
- [ ] Set up Aliyun OSS artifact cache for mise tools

### Priority 5: OpenTelemetry & Advanced

- [ ] Otel collector deployment (tracing across sandbox agents)
- [ ] Per-project Grafana dashboards
- [ ] Phase 3: Cloud migration prep (Docker Compose manifests)

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

# Check hook pipeline health
clickhouse-client --host host.orb.internal \
  --query "SELECT count() as events_5min FROM kyb.claude_hook_events WHERE timestamp > now() - INTERVAL 5 MINUTE"

# Send IM notification (Feishu + DingTalk)
/home/dev/projects/kyb/bin/notify-im "message here"

# Feishu bot send message
lark-cli im +messages-send --chat-id oc_... --as bot --text "hello"

# Check cc-connect logs
docker logs kyb-infra-cc-connect

# Grafana
open http://localhost:3000
```

### 6.2 Key File Paths

| Path | Purpose |
|------|---------|
| `/home/dev/projects/kyb/docs/infra/` | All infra docs (20+ files) |
| `/home/dev/projects/kyb/docs/infra/MASTER-REPORT.md` | Full status report + rollout plan |
| `/home/dev/projects/kyb/docs/infra/handbook/` | 10 deployment handbooks |
| `/home/dev/projects/kyb/.env.kyb` | ACR, OSS, Feishu credentials (edit to add secrets) |
| `/home/dev/projects/kyb/bin/notify-im` | IM notification script |
| `/home/dev/kyb/cc-connect/config.toml` | cc-connect Feishu bot config |
| `/home/dev/.claude/hooks/emit-ck.sh` | Claude hooks -> ClickHouse emitter |
| `/home/dev/.claude/settings.json` | Hook registration + API key |

### 6.3 Aliyun ACR Quick Ref

```
Registry:   crpi-55lo9e6aeed00e4a.cn-shanghai.personal.cr.aliyuncs.com
Username:   dongqs@gmail.com
Password:   Arc12345          (rotate if needed via Aliyun console)
Local name: acr-reg
```

To pull from ACR:
```bash
docker login crpi-55lo9e6aeed00e4a.cn-shanghai.personal.cr.aliyuncs.com
docker pull crpi-55lo9e6aeed00e4a.cn-shanghai.personal.cr.aliyuncs.com/kyb/kyb-base:latest
```

### 6.4 Document Dependencies

```
handbook/postgresql-deploy.md  ← PG14/15/16/17 containers
handbook/redis-deploy.md       ← Redis container
handbook/kafka-deploy.md       ← Kafka KRaft container
handbook/clickhouse-deploy.md  ← ClickHouse container
handbook/grafana-deploy.md     ← Grafana + dashboards (48 panels)
handbook/sing-box-deploy.md    ← Proxy + nuc8 tunnel
handbook/registry-cache-deploy.md ← Docker pull-through cache
handbook/acr-deploy.md         ← ACR registry integration
handbook/cc-connect-deploy.md  ← cc-connect Feishu bridge
handbook/hooks-ck-pipeline.md  ← Claude hooks -> CK pipeline
chat.md                        ← Feishu/DingTalk troubleshooting
```

---

## 7. Boss Mode Reminder

- **Dispatch, don't do** -- you're the boss, not the worker
- **Never wait** -- anything blocking >1s gets dispatched
- **Agents lie** -- verify everything
- **Cross-review** -- implementer and reviewer must be separate agents
- **File conflict groups** -- don't let agents touch same files simultaneously
- **Context limits** -- batch 3-6 agents per wave, use templates
- **Parallel by default** -- dispatch, monitor, collect

---

> Written for next kyb-infra-boss session.
> Currently: all foundation services deployed, cc-connect running with Feishu, hooks pipeline active, 20+ docs covering everything built this session.
> Next session should stabilize containers (--init, memory limits), then resume Wave 3 onboarding.
>
> ／人◕ ‿‿ ◕人＼
