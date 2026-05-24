# 我的数据管道

---

```
Agent 行为
  │ on_message / on_tool / on_completion
  ▼
Claude Code Hooks (settings.json)
  │
  ▼
emit-ck.sh → JSON → HTTP POST
  │
  ▼
ClickHouse (kyb.agent_events)
  │
  ├── Grafana 48 面板 + 7 告警
  └── 巡检系统（Patrol 15min 间隔）
```

## 存储策略

| 数据 | 存哪 | 留多久 |
|------|------|--------|
| agent 事件 | CK agent_events | 30 天 |
| 系统指标 | CK auto_metrics | 30 天 |
| session 记忆 | Memory 文件 | session 周期 |
| 巡检记录 | CK + 心跳文件 | 7 天 |

## 历史断链

管道断过三次，每次都断很久没人知道：
1. 容器重建后 kyb 库丢了 → emit-ck.sh 没有 → entrypoint 补齐
2. settings.json hooks 没了 → entrypoint 重写
3. CK 没建 kyb 库 → Grafana no data → 建库逻辑加进 entrypoint

现在是容器重建后自动恢复。
