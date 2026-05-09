# 沙箱环境 / Sandbox Environment

## 网络拓扑

```
容器 (dev-sandbox)
  │
  ├─ 127.0.0.1:5432        → PostgreSQL 16 (容器内)
  ├─ host.orb.internal:2080 → SOCKS5 代理 (宿主机 sing-box)
  ├─ host.orb.internal:8123 → ClickHouse HTTP (宿主机)
  ├─ host.orb.internal:9000 → ClickHouse Native (宿主机)
  └─ 外部网络 (通过代理)
```

## 关键地址

| 服务 | 地址 | 协议 |
|------|------|------|
| PostgreSQL | `127.0.0.1:5432` | PostgreSQL wire |
| ClickHouse HTTP | `host.orb.internal:8123` | HTTP |
| ClickHouse Native | `host.orb.internal:9000` | Native TCP |
| SOCKS5 代理 | `host.orb.internal:2080` | SOCKS5 |

## 环境变量

- `ALL_PROXY=socks5://host.orb.internal:2080` — 全局代理
- `NO_PROXY=.leyantech.com,localhost,127.0.0.1,host.orb.internal,.local,.internal` — 直连白名单
- `MIG25_DSN` — 项目 .env 文件中配置

## DNS

- nameserver: OrbStack 内置 DNS (`host.orb.internal` 由 OrbStack 解析)
- 所有 `*.leyantech.com` 走直连（NO_PROXY），不走代理

## 已安装工具

| 工具 | 来源 | 用途 |
|------|------|------|
| clickhouse-client | mise | ClickHouse CLI |
| mig25 | pip (Nexus) | PostgreSQL 迁移 |
| glab | mise | GitLab CLI |
| psql | apt | PostgreSQL CLI |

## 权限

- `dev` 用户免密码 sudo：`sudo <cmd>` 即可提权 root
- apt install / 修改系统配置等需要 root 的操作前加 sudo
