# Nested Subagent Dispatch — 实验记录与测试计划

**日期**: 2026-05-23
**实验者**: kyb-infra-boss

## 实验 1：subagent 能否派 subagent？

### 方法
1. boss 派了一个 subagent（层1）
2. 层1 subagent 尝试用 CronCreate 派一个层2 subagent
3. 层2 的任务：读 CLAUDE.md 第一行，报告文件名和创建时间

### 结果
- 层1 无法直接派层2（没有 DispatchSubagent / SpawnAgent 工具）
- 层1 用了 CronCreate 排了一个 1 分钟后的 cron
- cron **确实触发了**，但 prompt 回到了 boss session，不是层1 session
- 层2 任务成功执行了，但层1 已经结束，收不到结果

### 结论
- ❌ 同步嵌套（call-return）：不支持
- ✅ 异步链式（fire-and-forget via cron）：可行
- 模式：boss → subagent → cron schedule → boss 收到 → 派下一个

## 测试计划（明天做）

### 测试 1：多层链式极限
- boss → A → cron → boss → B → cron → boss → C
- 看最多能链几层？3层？5层？10层？
- 每层任务越来越简单（第N层只需 echo "layer N ok"）

### 测试 2：cron 冲突
- 同时排 3 个 cron，间隔 30 秒
- 看 3 个会不会依次触发？还是丢任务？

### 测试 3：cron 持久化
- `durable: true` 的 cron 是否真的能跨 session 存活？
- 退出 claude 重进，看 cron 还在不在

### 测试 4：信息回传
- cron 触发后，信息如何回到 boss？
- 写文件？飞书消息？GitLab issue？
- 哪种方式最可靠？

## 架构含义

如果链式 cron 能稳定跑通，那"boss → 方向长 → agent"的两层架构可以这样实现：
1. boss 派方向长（subagent）
2. 方向长调研完后，排一个 cron 通知 boss
3. boss 收到 cron 后，再派执行 agent
4. 方向长的 session 不需要等执行 agent 完成

这实际上是一个**事件驱动的工作流**，不是同步调用。
