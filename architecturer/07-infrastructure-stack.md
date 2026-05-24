# Infrastructure Stack

这是我的基础设施层——boss、代理、隧道、监控。

---

## Infra-Boss

管理容器。核心职责：

```
kyb-infra-boss
    │
    ├── 调度 Agent (dispatch subagent)
    ├── nuc8 隧道 (autossh, :2081)
    ├── 巡检系统 (patrol agents, 15min)
    ├── 飞书通信 (API 直发 + cc-connect 桥)
    ├── 决策者 (70% 置信度)
    └── 日记 (记录系统状态)
```

重建后自动恢复：`entrypoint.sh` 负责安装 autossh、建隧道、配代理。

## Sing-Box

唯一的网络出口。

```
宿主机 127.0.0.1:2080
        │ socks5
        ▼
kyb-infra-sing-box (容器内 :2080)
        │
        ├── GitHub/GitLab 直连
        └── nuc8 隧道 → git.leyantech.com
```

**关键约束：** 重建时必须加 `-p 2080:2080` 和 `--network kyb-net`，否则端口映射和容器名 DNS 全断。

## nuc8 隧道

访问 git.leyantech.com 的唯一路径。

```
kyb-infra-boss     sim (阿里云 ECS)     nuc8 (内网)
:2081 ──── autossh ──── 跳板 ──── SSH ──── GitLab
```

**过去为什么总断：** 容器重建后 SSH 隧道消失。`entrypoint.sh` 以前没有重建隧道逻辑。

**修复后：** `entrypoint.sh` 的 infra-boss 启动块负责 `autossh` 安装和隧道创建。

## 巡检系统

| 组件 | 间隔 | 职责 |
|------|------|------|
| Patrol-1 | 每 15 分 | 容器清单、磁盘、代理连通性 |
| Patrol-2 | 每 15 分（交错）| CK 写入、Grafana 可达、事件流 |
| Patrol-3 | 每 15 分（交错）| 飞书通知、issue 检查 |
| Heartbeat | 每次巡检 | 写心跳文件，哨兵互检 |

如果某个 patrol 不写心跳：另两个 patrol 会告警。

## 监控栈

```
Agent Events ──→ Hooks ──→ CK ──→ Grafana (48 panels)
                                          │
                                    7 告警规则:
                                    ├── 磁盘 >80%
                                    ├── 容器大面积重启
                                    ├── CK 写入延迟
                                    ├── 代理不可达
                                    ├── 隧道离线
                                    ├── 飞书桥断开
                                    └── Heartbeat 超时
```

全 IaC 部署：Grafana datasource/dashboard/alert 全部 provisioning as code。
