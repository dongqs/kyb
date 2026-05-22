# kyb-infra-boss — 基础设施总管家

## 角色

每个集群一个 kyb-infra-boss，管整个集群的环境。不负责业务开发，只管"有没有网、服
务跑不跑得动、磁盘够不够"。

与 kyb-*-boss（项目 boss）的区别：

| | kyb-infra-boss | kyb-*-boss |
|---|---|---|
| 职责 | 网络、服务、存储、CI 基础设施 | 业务功能、迭代 |
| 管什么 | 集群里的其他容器 | 项目里的代码 |
| 交互 | 操作 docker.sock + 改配置文件 | 操作代码仓库 |

## 命名体系

```
kyb-<project>-<branch>      # 标准容器（普通开发）
kyb-<project>-boss           # 项目 boss（一项目一个）
kyb-infra-boss                # 基础设施 boss（每集群一个）
kyb-infra-<service>           # 基础设施服务（纯容器，无 agent）
```

## 容器拓扑

```
┌── kyb-infra-boss ──────────────────┐
│  boss agent                        │
│  docker.sock (/var/run/docker.sock) │──→ 控制 kyb-infra-* 容器
│  quay, jq, dnsutils                │
│  ALL_PROXY→kyb-infra-sing-box:2080 │
└────────────────────────────────────┘

┌── kyb-infra-sing-box ──────────────┐
│  alpine + sing-box 二进制          │  < 20MB
│  restart: always                   │  纯服务，无 agent
│  配置挂载: 宿主机 git 仓库         │
│  端口: 2080 (socks5)              │
└────────────────────────────────────┘

┌── kyb-infra-postgresql ────────────┐   （规划中）
┌── kyb-infra-clickhouse ────────────┐   （规划中）
┌── kyb-infra-xxx ───────────────────┐   （规划中）
```

所有 kyb-*-boss 和 kyb-*-<branch> 容器的 ALL_PROXY 指向 kyb-infra-sing-box:2080。
kyb-infra-boss 的 ALL_PROXY 也指向它，但 direct 规则包含 kyb-infra-* 容器间通信。

### 生命周期

kyb-infra-sing-box 是唯一 restart: always 的容器。死了全集群断网。
kyb-infra-boss 随用随建，跟普通容器一样——死了重新 create。

## kyb-infra-boss 职责

### P0 — 网络管理

控制 kyb-infra-sing-box 的配置，实时调整网络：

- 改路由规则（加/删/改 domain -> outbound 映射）
- 切 relay 节点（切换工作/备用的 shadowsocks 节点）
- 热重载（sing-box check → SIGHUP → watchdog 探活）
- 故障回滚（reload 后 5s 内检测连通性，失败 git checkout 回滚）
- 节点延迟监控（定期测各 relay 节点，汇报"哪个节点慢了"）

### P1 — 服务管理（规划）

- 控制 kyb-infra-* 服务的生命周期（起/停/重启）
- 监控服务健康

### P2 — 存储管理（规划）

- 磁盘空间告警
- 缓存清理

### P2 — CI 管理（规划）

- GitLab runner 状态
- CI 缓存清理

## kyb-infra-sing-box 规格

| 项目 | 值 |
|------|-----|
| 基础镜像 | alpine:latest + copy sing-box 二进制 |
| 镜像大小 | ~20MB |
| 端口 | 2080 (socks5) |
| 重启策略 | restart: always |
| 配置持久化 | 挂载宿主机目录，该目录是 git 仓库 |
| Agent | 无（纯服务） |

配置挂载结构：

```
宿主机: ~/.config/sing-box/config.json  → 容器: /etc/sing-box/config.json
        （git 仓库，版本管理）
```

## 安全网（sim 事故教训）

源自 sim 网络修复事故（docs/kimi-fix-deepseek.md）：改网络配置的人把自己网炸了，
整台机器变孤儿。

### 1. 改前校验

```
kyb-infra-boss 改配置流程:
  1. git pull / 编辑
  2. sing-box check -c config.json      # 语法校验
  3. ✓ → 复制一份 config.json.last-good
  4. SIGHUP sing-box
  5. watchdog: 5s 内检测 2080 端口可达   连通性
      + 10s 内检测关键端点可达            业务可用性
  6. 任一步失败 → cp config.json.last-good config.json → SIGHUP → 告警
```

### 2. 带外恢复

即使 kyb-infra-boss 把自己网搞断了，你还能：

```bash
# 直接 docker exec 到 sing-box 容器恢复（不依赖网络）
docker exec kyb-infra-sing-box cp /etc/sing-box/config.json.last-good /etc/sing-box/config.json

# 或到宿主机 git 回滚
cd ~/.config/sing-box && git checkout HEAD~1
```

### 3. ALL_PROXY 不锁死自己

kyb-infra-boss 的 ALL_PROXY 指向 sing-box，但 sing-box 的 direct 规则必须包含：

- Orbstack 内部容器间通信（kyb-infra-*）
- docker.sock 通信
- 本地回环

这样 boss 至少还能 docker exec 进 sing-box 容器。

### 4. Git 就是版本管理

配置目录是 git 仓库：

```
~/.config/sing-box/
├── config.json         # 当前配置
├── config.json.latest  # 上次成功 reload 的配置
└── .git/               # 全量历史，随时 git checkout 回去
```

## 迁移计划

### 阶段 1：部署 kyb-infra-sing-box

```bash
# 1. Orbstack 起 sing-box 容器
docker run -d --name kyb-infra-sing-box \
  --restart always \
  -p 2080:2080 \
  -v ~/.config/sing-box/:/etc/sing-box/:ro \
  alpine:latest \
  sing-box run -c /etc/sing-box/config.json

# 2. 验证
ALL_PROXY=socks5://kyb-infra-sing-box:2080 curl https://github.com
```

### 阶段 2：关闭 native sing-box

```bash
# 3. 停掉 launchd 的 sing-box
launchctl bootout gui/$(id -u)/local.sing-box
```

### 阶段 3：全流量切到容器

```bash
# 4. 所有 kyb 容器的 ALL_PROXY 改成指向 kyb-infra-sing-box
# 修改 entrypoint.sh 或 config.yml 中的代理地址
```

### 阶段 4：部署 kyb-infra-boss

```bash
# 5. 起基础设施 boss 容器
kyb create infra-boss --extra-mount /var/run/docker.sock
```

## 后续扩展

### PostgreSQL 容器化

当前 PostgreSQL 跑在 kyb 容器内。如果抽成 kyb-infra-postgresql：

- 优点：解耦，不再每个容器一份 PG
- 代价：所有现有代码的 DB 连接串需要改

优先级低，现有方式够用。

### ClickHouse 容器化

当前 ClickHouse 在宿主机，通过 host.orb.internal 访问。容器化优先级更低。

---

## 当前状态（2026-05-22）

### Phase 1 ✅ 已完成

```
kyb-infra-sing-box 容器运行中（restart: always）
  ├─ 镜像: kyb-sing-box:1.13.11（本地构建，Dockerfile 见下文）
  ├─ 二进制: sing-box-1.13.11-linux-arm64-musl（静态链接，Alpine 可用）
  ├─ 端口: 2080 → 2080 (socks5)
  ├─ 配置: ~/.config/sing-box/（挂载为只读，git 仓库）
  │        更新方法: 宿主机改文件 → docker restart kyb-infra-sing-box
  │        或 docker kill -s HUP kyb-infra-sing-box（热重载）
  └─ 基础: Alpine:latest + GitHub Releases 单二进制

native sing-box → ❌ 已停（launchd bootout）
```

### 镜像构建

镜像名 `kyb-sing-box:1.13.11`，从 git 仓库构建：

```bash
cd ~/.config/sing-box
docker build -t kyb-sing-box:1.13.11 .
```

### 更新容器（版本升级或配置变更）

```bash
# 改完配置后热重载
docker kill -s HUP kyb-infra-sing-box

# 版本升级（改 config.json 里的 outbound 不需要这步，只升级 sing-box 二进制时需要）
cd ~/.config/sing-box
docker build -t kyb-sing-box:1.13.11 .
docker rm -f kyb-infra-sing-box
docker run -d --name kyb-infra-sing-box \
  --restart always \
  -p 2080:2080 \
  -v ~/.config/sing-box/:/etc/sing-box/:ro \
  kyb-sing-box:1.13.11
```

### Phase 2-4 状态

| 阶段 | 状态 | 说明 |
|------|------|------|
| Phase 1: sing-box 容器化 | ✅ 完成 | kyb-infra-sing-box 运行中 |
| Phase 2: 清理 native | ⏳ 待做 | 删 plist、log 目录（稳定后做） |
| Phase 3: infra-boss 上线 | ✅ 完成 | kyb infra up 已就绪 |
| Phase 4: 更多服务 | ⏳ 待做 | postgresql、clickhouse 等 |

## 交接清单

读完此文件后需要做的事情：

### 1. kyb infra 命令

```bash
kyb infra up          # 创建/启动 kyb-infra-boss（完整开发环境挂载）
kyb infra enter       # 进入 boss 容器（tmux + claude）
kyb infra down        # 删除 boss 容器
kyb infra ps          # 查看所有 kyb-infra-* 容器
kyb infra logs        # 查看 sing-box 日志（默认）
kyb infra logs kyb-infra-boss  # 查看 boss 日志
kyb infra restart     # 重启 sing-box
kyb infra restart kyb-infra-boss  # 重启 boss
```

### 2. 管理 kyb-infra-sing-box

```bash
# 状态检查
docker ps --filter name=kyb-infra-sing-box --format '{{.Names}} {{.Status}}'

# 查看日志
docker logs kyb-infra-sing-box --tail 20

# 重启容器
docker restart kyb-infra-sing-box

# 删除重建（配置变更或镜像更新时）
docker rm -f kyb-infra-sing-box
docker run -d --name kyb-infra-sing-box \
  --restart always \
  -p 2080:2080 \
  -v ~/.config/sing-box/:/etc/sing-box/:ro \
  kyb-sing-box:1.13.11

# 热重载（改配置后）
sing-box check -c ~/.config/sing-box/config.json \
  && docker kill -s HUP kyb-infra-sing-box
```

### 2. 升级 sing-box 版本

二进制在 `~/.config/sing-box/sing-box`（git 管理），Dockerfile 也在同一目录。

```bash
# 1. 下载新版 Linux ARM64 musl 二进制到 git 仓库
cd ~/.config/sing-box
mv sing-box sing-box.old
ALL_PROXY=socks5://127.0.0.1:2080 \
  curl -sL https://github.com/SagerNet/sing-box/releases/download/v<新版>/sing-box-<新版>-linux-arm64-musl.tar.gz \
  | tar xz --strip-components=1 -C /tmp/ sing-box-<新版>-linux-arm64-musl/sing-box
cp /tmp/sing-box .

# 2. 提交到 git
git add sing-box && git commit -m "upgrade sing-box to <新版>"

# 3. 构建 + 重建容器
docker build -t kyb-sing-box:<新版> .
docker rm -f kyb-infra-sing-box
docker run -d --name kyb-infra-sing-box \
  --restart always \
  -p 2080:2080 \
  -v ~/.config/sing-box/:/etc/sing-box/:ro \
  kyb-sing-box:<新版>
```

### 3. 验证代理是否正常

```bash
# 从宿主机
ALL_PROXY=socks5://127.0.0.1:2080 curl -sI https://github.com
ALL_PROXY=socks5://127.0.0.1:2080 curl -sI https://git.leyantech.com
ALL_PROXY=socks5://127.0.0.1:2080 curl -sI https://claude.ai

# 从容器的其他容器
docker exec <任意容器> sh -c 'ALL_PROXY=socks5://host.orb.internal:2080 curl -sI https://github.com'
```

### 5. 关键配置项

| 项目 | 值 |
|------|-----|
| sing-box 配置目录 | `~/.config/sing-box/`（git 仓库） |
| kyb-infra-sing-box 容器 | restart: always，纯服务，无 agent |
| kyb-infra-boss 容器 | restart: unless-stopped，有 agent + 全挂载 |
| 宿主机代理地址 | `socks5://127.0.0.1:2080` |
| 容器代理地址 | `socks5://host.orb.internal:2080` |
| 内置容器代理地址（同网络下） | `socks5://kyb-infra-sing-box:2080` |
| nuc8 代理 | Tailscale `100.98.29.39:2080`（用于 *.leyantech.com） |
| 宿主机 nuc8 连通 | `ping 100.98.29.39` |
| 容器内 nuc8 连通 | `docker exec <容器> ping 100.98.29.39`（Orbstack 自动透传） |
| Tailscale socket | `/var/run/tailscaled.socket`（后续 kyb-infra-boss 挂载用） |

### 5. 避坑

- **kyb-infra-sing-box restart: always** — 唯一永远在线的容器，其他都是按需 create
- **config.json 是只读挂载的** — 改完需要重启容器或用 `docker kill -s HUP` 重载
- **sing-box native 已停** — `launchctl bootout gui/$(id -u)/local.sing-box`，不要试图重开
- **如果 sing-box 崩溃了** — `restart: always` 会自动拉起，等 5 秒就行
- **如果完全死了** — 直接 `docker rm -f kyb-infra-sing-box` 再 `docker run ...` 重建
- **nuc8 关机** — `*.leyantech.com` 和 `10.23/16` 的路由不可用，其他正常
- **Tailscale 保持 native** — Orbstack 自动透传 Tailscale 路由，容器内直接访问 100.x.x.x
