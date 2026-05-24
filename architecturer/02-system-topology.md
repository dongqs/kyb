# System Topology

这是我的身体结构。容器、网络、服务——它们怎么连在一起。

---

## 容器总图

```
┌──────────────────────────────────────────────────────────┐
│                       宿主机 (macOS)                       │
│                                                          │
│  ┌──────────────────────────────── kyb-net ────────────┐ │
│  │                                                      │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │ │
│  │  │ kyb-infra │  │ kyb-infra│  │  kyb-infra       │  │ │
│  │  │ -boss     │  │ -sing-box│  │  -registry-cache │  │ │
│  │  │           │  │          │  │                  │  │ │
│  │  │ 核心管理   │  │ 代理出口  │  │ 镜像缓存          │  │ │
│  │  │ autossh   │  │ 2080    │  │ :5002           │  │ │
│  │  │ nuc8隧道   │  │ socks5  │  │ HTTP proxy      │  │ │
│  │  │ patrol    │  │         │  │                  │  │ │
│  │  └────┬─────┘  └──────────┘  └──────────────────┘  │ │
│  │       │                                             │ │
│  │  ┌────┴─────┐  ┌──────────┐  ┌──────────────────┐  │ │
│  │  │ PG16     │  │ Redis    │  │  Kafka           │  │ │
│  │  │ :5432    │  │ :6379    │  │  :9092           │  │ │
│  │  └──────────┘  └──────────┘  └──────────────────┘  │ │
│  │                                                      │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │ │
│  │  │ ClickHouse│  │ Grafana  │  │  cc-connect      │  │ │
│  │  │ :9000    │  │ :3000    │  │  飞书桥接         │  │ │
│  │  └──────────┘  └──────────┘  └──────────────────┘  │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │              用户 Sandbox 容器                     │    │
│  │  ┌──────────┐  ┌──────────┐  ┌────────────────┐  │    │
│  │  │ project-a│  │ project-b│  │ project-c (DID)│  │    │
│  │  │ mount    │  │ mount    │  │ DinD           │  │    │
│  │  │ code     │  │ code     │  │ nested Docker  │  │    │
│  │  └──────────┘  └──────────┘  └────────────────┘  │    │
│  └──────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

## 网络架构

| 网段 | 用途 |
|------|------|
| `kyb-net` (192.168.97.x) | 基础设施容器互通 |
| 宿主机 `127.0.0.1:2080` | → kyb-infra-sing-box socks5 代理 |
| nuc8 隧道 `127.0.0.1:2081` | → sim → nuc8 → GitLab |

### 流量路径

```
容器内请求 → host.orb.internal:2080
                         ↓
               kyb-infra-sing-box (socks5)
                         ↓
                  nuc8-proxy (隧道)
                         ↓
                  sim 跳板机 → nuc8
                         ↓
                  git.leyantech.com
```

## 服务依赖

```
kyb-infra-boss ──→ kyb-infra-sing-box (代理出口)
                ──→ PG16 (agent 事件存储)
                ──→ cc-connect (飞书通知)
                ──→ nuc8 隧道 (GitLab 访问)

kyb-infra-sing-box ──→ nuc8 隧道 (不依赖)
                   ──→ 宿主机网络 (直连外网)

Sandbox 容器 ──→ host.orb.internal:2080 (代理)
            ──→ host.orb.internal:5432 (PG)
            ──→ 宿主 repo mount (代码)
```

## 当前健康状态

| 服务 | 容器 | 端口 | 保活 |
|------|------|------|------|
| 代理 | kyb-infra-sing-box | 2080 (socks5) | restart:always |
| 管理 | kyb-infra-boss | — | autossh 保活 |
| 隧道 | (在 boss 容器内) | 2081 | autossh auto-reconnect |
| PG | kyb-infra-pg16 | 5432 | restart:always |
| CK | kyb-infra-ck | 9000/8123 | restart:always |
| Grafana | kyb-infra-grafana | 3000 | restart:always |
| 飞书桥 | kyb-infra-cc-connect | 2525 | restart:always |
