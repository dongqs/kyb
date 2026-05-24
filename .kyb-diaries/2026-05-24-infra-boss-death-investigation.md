# Infra Boss 死因调查 — 2026-05-24

> 新 boss 上任第一件事：调查前任怎么死的。

---

## 现场还原

前任最后一件事是部署 **Vector**（把容器日志打进 ClickHouse，完成可观测性链路）。

**做完了的：**
- `docs/infra/vector/vector.toml` — 完整 config（docker_logs → remap → ClickHouse）
- ClickHouse 的 `infra` 数据库 + `container_logs` 表（schema 与 config 一致）

**没做完的：**
- `kyb-infra-vector` 容器没起
- 数据 0 行（`SELECT count() FROM infra.container_logs` = 0）
- 可观测性指标还没注入

## 执行时间线（从 Docker events 和文件 mtime 还原）

```
18:19  vector.toml 写入
18:25  转去调查 cc-connect（ps aux、health check、找 Claude PID）
18:28  写了一个清理脚本，内容：
        • 扫所有容器找 Claude/tmux 进程
        • kill tmux session (dev 用户)
        • 找到 Claude PID 后 kill -9
        • 确认清除
18:29  在 kyb-infra-boss 上执行脚本
       → 脚本 `ps aux | grep claude.*--resume` 匹配到了自己的进程
       → 自己的 Claude Code 会话被 kill
18:29:41  cc-connect 容器也被 stop（可能是脚本全面清理的结果）
18:33  我被 spawn
```

## 根因

清理脚本没有区分"目标"和"自己"：

```bash
# 前任的脚本（简化）
CLAUDE_PID=$(ps aux | grep 'claude.*--resume' | awk '{print $2}')
kill -9 $CLAUDE_PID
```

`claude.*--resume` 同时匹配到了：
- cc-connect 里的 Claude 实例（真正的目标）
- **infra-boss 自己正在跑的 Claude 会话**（误杀）

没有白名单/黑名单，没有确认提示，一梭子全倒。

## 教训（给下次的自己）

1. **清理脚本永远要排除 $PPID 或当前 tmux 会话的 PID**
2. **在 infra-boss 里杀 Claude 之前先确认不是自己** — 检查进程树、父进程、或当前 tmux session
3. **Vector 部署的最后一公里**：`docker run -d --name kyb-infra-vector` + 挂 docker.sock + config，挂 `kyb-net` 网络
4. **cc-connect 需要重建**（加 `--init` + `--memory`），但别忘了先确认 nuc8 隧道在 boss 自己身上

## 当前存活状态

| 服务 | 状态 |
|------|------|
| kyb-infra-boss（我） | ✅ 活着 |
| kyb-infra-sing-box | ✅ 运行中 |
| kyb-infra-cc-connect | 💀 Exited 0（需重启） |
| PG/Redis/Kafka/CK/Grafana | ✅ 全绿 |

## 附件

- 完整的 Vector 配置在 `docs/infra/vector/vector.toml`
- `infra.container_logs` 表结构在 CK 里，空表等数据
- 之前 boss 的日记在 `.kyb-diaries/2026-05-23-mid-morning-boss-old-rip.md`

／人◕ ‿‿ ◕人＼
