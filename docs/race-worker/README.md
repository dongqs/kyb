# race-worker (192.168.215.4)

## 概述

race-worker 是一台运行在 **OrbStack** 上的 **Ubuntu 24.04** Docker 容器，宿主机为 **Apple Silicon (M 系列)** Mac。

| 项目 | 值 |
|------|-----|
| IP | 192.168.215.4/24 |
| 访问方式 | `ssh dev@192.168.215.4` |
| OS | Ubuntu 24.04.4 LTS (Noble Numbat) |
| 架构 | aarch64 (ARM 64) |
| CPU | 10 核 Apple Silicon @ 2.0 GHz |
| 内存 | 16 GiB RAM + 16 GiB Swap |
| 磁盘 | 8TB 主存储 (btrfs), root overlay 79G (65% used) |
| 网络 | 内网可达, 外网不通 |
| 监听端口 | 仅 22/SSH |

## 工具链

- **语言**: Python 3.10, Node 25, Ruby 3.3
- **工具管理**: mise 2026.5.12
- **容器**: Docker CLI 29.1.3 (无 daemon)
- **数据库客户端**: PostgreSQL 16, ClickHouse 26
- **Git 相关**: git 2.43, glab 1.92, claude-code 2.1

## 文档索引

| 文件 | 内容 |
|------|------|
| [01-physical.md](01-physical.md) | CPU, 内存, 磁盘, 硬件型号 |
| [02-os.md](02-os.md) | 操作系统, 用户, 环境 |
| [03-network.md](03-network.md) | IP, 端口, DNS, 连通性 |
| [04-runtime.md](04-runtime.md) | 语言, 工具, 运行时 |
| [05-services.md](05-services.md) | Docker, 数据库, 服务 |

## 访问

```bash
# 从 kyb-race-worker-1 容器 SSH
docker exec -u dev -e HOME=/home/dev kyb-race-worker-1 ssh dev@192.168.215.4
```

## 备注

- 宿主机是 OrbStack 管理的 Apple Silicon Mac
- 仅暴露 SSH 端口，无其它网络服务
- 无外网访问能力 (ping 8.8.8.8 不通)
- 适合作为编译/测试 worker 节点
