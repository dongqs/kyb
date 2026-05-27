# 我长什么样

---

## 容器总图

```
┌─────────────────────────────────────────────────────┐
│                     macOS 宿主机                       │
│                                                      │
│   kyb-net ────────────────────────────────────────┐  │
│   │                                                │  │
│   │  kyb-infra-boss             大脑：调度、隧道、日记│  │
│   │  kyb-infra-sing-box         网络出口：socks5 :2080│  │
│   │  kyb-infra-registry-cache   镜像缓存 :5002       │  │
│   │  kyb-infra-pg16             PG 16 :5432         │  │
│   │  kyb-infra-redis            Redis :6379         │  │
│   │  kyb-infra-kafka            Kafka :9092         │  │
│   │  kyb-infra-ck               ClickHouse :9000    │  │
│   │  kyb-infra-grafana          Grafana :3000       │  │
│   │  kyb-infra-cc-connect       飞书桥 :2525        │  │
│   └──────────────────────────────────────────────────┘  │
│                                                      │
│   Sandbox 容器群（不固定）                              │
│   ┌──────────┐ ┌──────────┐ ┌──────────────────┐    │
│   │ project-a│ │ project-b│ │ project-c (DID)  │    │
│   │ mount    │ │ mount    │ │ 嵌套 Docker      │    │
│   └──────────┘ └──────────┘ └──────────────────┘    │
└──────────────────────────────────────────────────────┘
```

## 网络路径

```
Sandbox 容器 → host.orb.internal:2080 (socks5)
                       ↓
              kyb-infra-sing-box
                  ↓           ↓
           直连外网      nuc8 隧道 → GitLab
```

## 网段

| 网络 | 用途 |
|------|------|
| kyb-net (192.168.97.x) | infra 容器互通 |
| 宿主机 :2080 | → sing-box socks5 |
| boss :2081 | → nuc8 隧道 |

## 健康状态

| 服务 | 保活 | 依赖 |
|------|------|------|
| sing-box | restart:always | 无 |
| infra-boss | autossh | sing-box(代理) |
| PG/CK/Grafana | restart:always | kyb-net |
