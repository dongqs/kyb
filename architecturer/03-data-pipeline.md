# 数据管道

agent 的每个行为怎么变成 Grafana 上的一条曲线。我踩过最大的坑就是这个管子断了没人知道。

---

## 数据流

```
Agent 干了一件事（发了条消息、调了个工具、完成了任务）
       │
       ▼
Claude Code Hooks
  └─ on_message
  └─ on_tool_use
  └─ on_completion
       │
       ▼
emit-ck.sh  →  JSON 格式化 → HTTP POST → ClickHouse
       │                                          │
       │                                          ├── Grafana (48 面板)
       │                                          └── 巡检 (心脏检测)
       │
       └── 也写 Memory 文件（短期记忆用）
```

## 这个管子断了三次

每次断的原因都不同，但结果一样：数据没了，但没人知道。

| # | 断的原因 | 发现方式 | 修复 |
|---|---------|---------|------|
| 1 | 容器重建后 kyb 库丢了，emit-ck.sh 不在 | 巡检发现 | entrypoint 启动时检查并补齐 |
| 2 | settings.json 的 hooks 配块被覆盖了 | 对比上一任配置发现 | 统一放 entrypoint 里写 |
| 3 | CK 里没建 kyb 库，events 写到哪 | Grafana 全是 no data | 加建库逻辑到 entrypoint |

三个问题本质是同一个：**配置不是基建，配置是负债。** 手动配的东西容器重建就丢。现在能放 entrypoint 的都放 entrypoint，不能放的就 IaC。

## 我现在怎么保证它通着

每 15 分钟 patrol agent 做三件事：
1. 写一条测试事件到 CK
2. 查一下 Grafana API 看看数据到了没
3. 如果断了发飞书告警

还有三个 patrol 互相关心跳。一个不写了另外两个会叫。

## 存储策略

| 数据 | 存哪 | 留多久 | 为什么 |
|------|------|--------|--------|
| agent 事件 | CK agent_events | 30 天 | 查最近的事够了 |
| 系统指标 | CK auto_metrics | 30 天 | 跟 Grafana 留存对齐 |
| session 记忆 | Memory 文件 | session 生命周期 | 清了也没关系 |
| 巡检记录 | CK + 心跳文件 | 7 天 | 够发现模式就行 |
