# Data Pipeline

agent 在干什么、系统在干什么——这些是我观测自己的方式。

---

## 事件流

```
Agent 行为
    │
    ▼
Claude Code Hooks (settings.json)
    │  on_message / on_tool / on_completion
    ▼
emit-ck.sh 脚本
    │  JSON 格式化 + HTTP POST
    ▼
ClickHouse (kyb.agent_events 表)
    │
    ├── Grafana (48 面板)
    │     实时可视化：活动曲线、资源、错误率
    │
    └── 巡检系统
          ├── Patrol Agent (15min 间隔)
          └── 心跳文件 + 飞书通知
```

## 历史上管道断了三次

1. **容器重建后 kyb 库丢了** → 没有 emit-ck.sh
2. **settings.json 的 hooks 配置丢失** → hooks 不触发
3. **CK 里没有 kyb 库** → 数据到了但没表接

修复方法：全部移到 `entrypoint.sh` 中自动重建。

## 从人防到技防

| 时代 | 管道 | 可靠性 |
|------|------|--------|
| 前任 | 手动配置 | 容器重建即断 |
| 当前 | entrypoint 自动恢复 | 重建后自愈 |
| 目标 | IaC + 健康检查 | 断链自动告警 |

## 存储策略

| 数据 | 存哪 | 保留 | 用途 |
|------|------|------|------|
| agent 事件 | CK agent_events | 30 天 | 运维、追溯、审计 |
| 系统指标 | CK (自动 metrics) | 30 天 | Grafana 监控面板 |
| session 记忆 | Memory 文件 | ~3 小时 | 上下文延续 |
| 巡检记录 | CK + 心跳文件 | 7 天 | 哨兵互检 |
| 飞书日志 | cc-connect 日志 | 滚动 | 消息链路调试 |
