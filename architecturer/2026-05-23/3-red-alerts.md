# 三大红色警报

**日期：** 2026-05-23
**来源：** 15 路全面体检

## 🔴 #1: Hooks → CK 管道完全断裂

管道的三个环节全部消失：
- CK 里没有 `kyb` 库
- `emit-ck.sh` 脚本不在
- `settings.json` 里的 hooks 配置块不在

当前 session 的一条 event 都没进去。上一任的 6700+ 条成为历史遗迹。

## 🔴 #2: 15/16 容器缺 --init + 全部无内存限制

整个 infra 集群里唯一符合规范的容器是 `kyb-infra-boss2`（有 tini + 4GiB 限制）。其余 15 个——包括 PG、Redis、Kafka、CK、Grafana、sing-box、cc-connect——全裸。

- 没 `--init` = 僵尸累积
- 无限制 = 死循环能 OOM 穿宿主

这是交接清单 Priority 1 的原项，没人动过。

## 🔴 #3: Registry Cache 文档 7 处失真

容器名、网络模式、端口、代理类型、代理目标——全错：

| 项 | 文档写的 | 实际跑的 |
|----|----------|----------|
| 容器名 | `kyb-infra-registry:5000` | `kyb-registry-cache:5002` |
| 网络 | bridge | host |
| 代理 | SOCKS5 | HTTP |

拿着文档去连 registry 的人只会撞墙。
