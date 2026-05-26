# kyb-infra Component Inventory

> 2026-05-26 现状。所有受 infra 管理的组件。

## 节点

| 节点 | 位置 | IP | 规格 | 角色 |
|------|------|-----|------|------|
| 火山云 ECS | cn-shanghai | 124.174.68.38 / 100.115.201.70 | 4C16G 40G | infra 主节点 |
| 阿里云 sim | cn-shanghai | 47.100.71.220 / 100.113.24.32 | 2C2G 40G | 跨厂商备机 |
| nuc8 | 办公室 | 100.98.29.39 (Tailscale) | 31G 40G | 隧道终点、终极救生艇 |
| Mac | 随身 | 100.104.244.99 (Tailscale) | — | 栖息地、指挥站 |

## 火山云 ECS（主站）

### Docker 容器

| 容器名 | 镜像 | 端口 | 重启 | 内存 | 用途 |
|--------|------|------|:----:|:----:|------|
| `kyb-infra-sing-box` | `kyb-sing-box:1.13.11` | 2080 (host) | always | 不限制 | SOCKS5 代理入口 |
| `kyb-infra-nuc8-tunnel` | `kyb-nuc8-tunnel:latest` | 2081 (kyb-net) | always | 64m | SSH 隧道到 nuc8 |
| `kyb-infra-clickhouse` | `clickhouse/clickhouse-server:24.2-alpine` | 8123 (kyb-net) | always | 512m | 容器日志存储 |
| `kyb-infra-vector` | `timberio/vector:latest-alpine` | — | always | 128m | 日志采集 → CK |
| `kyb-infra-grafana` | `grafana/grafana:latest` | 3000 (Tailscale) | always | 256m | 可视化 |

### 主机服务

| 服务名 | 状态 | 用途 |
|--------|------|------|
| `kyb-monitor.service` | active | 健康端点 :2082 |
| `kyb-monitor-heartbeat.timer` | active | 每 60s 写心跳 |
| `kyb-sing-box.service` | disabled | 原生 sing-box 保活（切 Docker 后禁用） |
| `kyb-nuc8-tunnel.service` | disabled | 原生 SSH 隧道保活（切 Docker 后禁用） |
| `ufw` | active | 仅开 22, 2080, 2082 |
| `fail2ban` | active | SSH 暴力破解防护 |
| Docker daemon | active | 容器运行时 |
| tailscaled | active | Mesh VPN |

### 持久数据

| 路径/卷 | 内容 | 备份 |
|---------|------|:----:|
| `kyb-clickhouse-data` volume | CK 数据表 | 无（日志可重采） |
| `/etc/sing-box/` (git) | sing-box 配置 | git 仓库 |
| `/opt/kyb-monitor/` | 监控程序 | 代码在 git |
| `/var/log/kyb-monitor/` | 心跳日志 | 无（可重采） |
| `/root/docker-build/` | Dockerfile + 二进制 | 无 |

### 网络

| 名称 | 网段 | 成员 |
|------|------|------|
| `kyb-net` (bridge) | 172.18.0.0/16 | 所有 kyb-infra-* 容器 |

### 关键配置

| 文件 | 用途 |
|------|------|
| `/etc/sing-box/config.ip.json` | 当前生效的 sing-box 配置（nuc8-tunnel → 172.18.0.100:2081） |
| `/etc/sing-box/config.container.json` | 容器名版配置（备选，sing-box DNS 不认） |
| `/etc/sing-box/config.docker.json` | 旧 IP 版配置（已废弃） |
| `/etc/systemd/system/docker.service.d/proxy.conf` | Docker daemon 代理配置 |
| `/etc/vector/vector.toml` → 实际是 .yaml | Vector 流水线配置 |

## 阿里云 sim（备机）

### Docker 容器

| 容器名 | 镜像 | 端口 | 用途 |
|--------|------|------|------|
| `docker-cache` | `registry:2` | 127.0.0.1:5000 | 镜像缓存 |

### 现存服务

| 服务 | 端口 | 备注 |
|------|:----:|------|
| OpenResty | 80/443 | `map.yaosuguoduo.com` 等业务 |
| SSH | 22 | hardened, UFW |

### 状态

- 已加固（PasswordAuth no, UFW, fail2ban）✅
- 未部署 infra 容器（待做）

## nuc8

### 角色
- SSH 隧道终点（`-D 2081`）
- 无 GFW 互联网访问（GitHub 直连 200）
- 潜在终极救生艇

### 已装
- Docker 29.4.2
- Tailscale 100.98.29.39
- 31G RAM, 22G 可用磁盘

### 状态
- 未被 infra 管理
- 未部署 infra 容器

## Mac

### Docker 容器（部分）

| 容器名 | 状态 | 用途 |
|--------|:----:|------|
| `kyb-infra-sing-box` | ✅ | 本地代理 |
| `kyb-infra-nuc8-tunnel` | ✅ | 本地隧道 |
| `kyb-infra-clickhouse` | ✅ | 本地 CK（可能迁走） |
| 各种项目沙箱 | ⚡ | 按需创建 |

### 状态
- 栖息地，不做生产负载
- 用于日常开发 + 紧急 SSH 救援

## 外部依赖

| 依赖 | 用途 | 灾备 |
|------|------|:----:|
| GitLab (git.leyantech.com) | 代码仓库、CI | 无（完全外部） |
| Shadowsocks relays (HK2/JP1 等) | 国际出站 | 多节点（配置了多个） |
| Tailscale | 节点间网络 | 自身高可用 |
| Docker Hub | 镜像 | 被墙，通过代理 + 本地缓存 |
| GitHub (Releases) | 二进制下载 | 被墙，通过代理 |
| Aliyun/Volcengine API | 云资源管理 | 跨厂商 |

---

> 记录时间：2026-05-26
