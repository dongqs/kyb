# 服务层 — {new-machine-remote-hostname}

我是谁：记录 remote:ssh {new-machine-ssh-user}@{new-machine-ssh-host} 的运行服务。
我在哪：remote:~/.claude/docs/05-services.md
我要干什么：盘点 Docker、数据库、后台进程。
我不干什么：不记录硬件、OS 核心配置。

## 可用工具

> 📝 操作提示：按协议执行。

```bash
# === local ===
cat > /tmp/kyb-{ts}-svc-tools.sh << 'SCRIPT'
for tool in docker docker-compose podman kubectl systemctl ps ss lsof; do
  command -v "$tool" >/dev/null && echo "$tool: $(which $tool)" || echo "$tool: NOT INSTALLED"
done
SCRIPT
# === local→remote === scp && ssh && commit
```

| 工具 | 已装 | 用途 |
|------|------|------|
| docker | Y / N | 容器管理 |
| docker compose | Y / N | 容器编排 |
| podman | Y / N | 替代 Docker |
| kubectl | Y / N | Kubernetes |
| systemctl | Y / N | 系统服务管理 |
| ps | Y / N | 进程查看 |
| ss / netstat | Y / N | 端口查看 |
| lsof | Y / N | 文件/端口查看 |

### 确认

我确认以上工具清单完整。
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)

## Docker

> 📝 操作提示：按协议执行。

```bash
# === local ===
cat > /tmp/kyb-{ts}-svc-docker.sh << 'SCRIPT'
docker --version 2>/dev/null
docker info --format 'Server: {{.ServerVersion}}' 2>/dev/null
echo "=== containers ==="
docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
echo "=== images ==="
docker images -q 2>/dev/null | wc -l
echo "=== disk ==="
docker system df 2>/dev/null | tail -3
SCRIPT
# === local→remote === scp && ssh && commit
```

| 项目 | 值 |
|------|-----|
| Docker 版本 | ______ |
| Docker daemon | ______ |
| 运行中容器 | ______ |
| 全部容器 | ______ |
| 镜像数 | ______ |
| 镜像总大小 | ______ |

### 运行中容器

| 容器名 | 镜像 | 状态 | 端口 |
|--------|------|------|------|
| ______ | ______ | ______ | ______ |
| ______ | ______ | ______ | ______ |

### 确认

我确认以上 Docker 信息正确。
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)

## 数据库

> 📝 操作提示：逐个检查。用 ss 看端口是否监听。

```bash
# === local ===
cat > /tmp/kyb-{ts}-svc-db.sh << 'SCRIPT'
for port in 5432 3306 6379 9000 27017 9200; do
  ss -tlnp | grep -q ":$port " && echo "port $port: LISTENING ($(ss -tlnp | grep ":$port " | awk '{print $7}'))" || echo "port $port: closed"
done
SCRIPT
# === local→remote === scp && ssh && commit
```

| 数据库 | 已装 | 运行中 | 端口 | 连接串 |
|--------|------|--------|------|--------|
| PostgreSQL | Y / N | Y / N | 5432 | postgresql://____ |
| MySQL / MariaDB | Y / N | Y / N | 3306 | mysql://____ |
| Redis | Y / N | Y / N | 6379 | redis://____ |
| ClickHouse | Y / N | Y / N | 9000 | clickhouse://____ |
| SQLite | Y / N | Y / N | 文件 | ______ |
| MongoDB | Y / N | Y / N | 27017 | mongodb://____ |
| Elasticsearch | Y / N | Y / N | 9200 | http://____ |
| 其他______ | Y / N | Y / N | ____ | ______ |

### 确认

我确认以上数据库信息正确。
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)

## 后台进程

```bash
# === local ===
cat > /tmp/kyb-{ts}-svc-ps.sh << 'SCRIPT'
ps aux --sort=-%mem | head -10
SCRIPT
# === local→remote === scp && ssh && commit
```

| 进程名 | 用户 | CPU% | 内存% | 运行时间 |
|--------|------|------|-------|---------|
| ______ | ______ | ____ | ____ | ______ |
| ______ | ______ | ____ | ____ | ______ |
| ______ | ______ | ____ | ____ | ______ |
| ______ | ______ | ____ | ____ | ______ |
| ______ | ______ | ____ | ____ | ______ |

### 确认

我确认以上进程信息正确。
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)

## 探索日志

| # | 时间 (精确到秒) | 操作 | 结果 | 耗时 | commit |
|---|------|------|------|------|--------|
| 1 | | 可用工具 | 成功/失败 缺:____ | __s | |
| 2 | | Docker 状态 | 成功/失败 | __s | |
| 3 | | 数据库扫描 | 成功/失败 | __s | |
| 4 | | 后台进程 | 成功/失败 | __s | |

## 最终复查

我已复查整个文档，所有操作已记录并 commit。

总耗时：____ 分钟
签名：kyb-{new-machine-remote-hostname}  日期：________ (精确到秒)
