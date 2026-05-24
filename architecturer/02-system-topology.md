# 系统拓扑

我的容器怎么摆的，网络怎么走的。一张拓扑图解决。

---

## 容器布局

下面是我跑着的容器。画了张 ASCII 图方便回忆：

```
┌─────────────────────────────────────────────────────┐
│                     macOS 宿主机                       │
│                                                      │
│   kybe-net ──────────────────────────────────────┐  │
│   │                                               │  │
│   │  kyb-infra-boss    ← 大脑。调度、隧道、日记    │  │
│   │  kyb-infra-sing-box ← 唯一网络出口，socks5    │  │
│   │  kyb-infra-registry-cache ← Docker 镜像缓存   │  │
│   │                                               │  │
│   │  kyb-infra-pg16     ← agent 事件、项目数据    │  │
│   │  kyb-infra-redis                              │  │
│   │  kyb-infra-kafka     ← 可选的 event bus       │  │
│   │  kyb-infra-ck        ← 中期记忆 (30天)        │  │
│   │  kyb-infra-grafana   ← 48 面板、7 告警        │  │
│   │  kyb-infra-cc-connect ← 飞书桥                │  │
│   │                                               │  │
│   └───────────────────────────────────────────────┘  │
│                                                      │
│   Sandbox 容器群 ← 不固定。跑用户项目                  │
│   ┌──────────┐ ┌──────────┐ ┌──────────────────┐    │
│   │ project-a│ │ project-b│ │ project-c (DID)  │    │
│   │ mount    │ │ mount    │ │ 嵌套容器跑测试    │    │
│   │ code     │ │ code     │ │ tar pipe 传 JDK  │    │
│   └──────────┘ └──────────┘ └──────────────────┘    │
└──────────────────────────────────────────────────────┘
```

## 网络怎么走

最头疼的部分。理清楚之后：

```
Sandbox 里跑的命令
       │
       ▼
host.orb.internal:2080 (socks5)
       │
       ▼
kyb-infra-sing-box (走代理还是直连)
       │
       ├── GitHub/GitLab 直连
       └── git.leyantech.com
              │
              ▼
       kyb-infra-boss:2081 (nuc8 隧道)
              │
              ▼
       nuc8 (跳板机)
              │
              ▼
       git.leyantech.com
```

sing-box 是唯一出口。它挂了所有容器都断网。

## 服务依赖（我记这个是因为每次重建都忘参数）

| 服务 | 依赖 | 重建时千万记住 |
|------|------|---------------|
| sing-box | 无 | `-p 2080:2080` + `--network kyb-net` |
| infra-boss | sing-box (代理) | entrypoint 会装 autossh + 建隧道 |
| nuc8 隧道 | sim 在线、nuc8 在线 | autossh 自动保活，不用管 |
| Grafana | CK | Provisioning as code，不用手动配 |
| cc-connect | PROXY | SHELL 环境变量必须设 |
