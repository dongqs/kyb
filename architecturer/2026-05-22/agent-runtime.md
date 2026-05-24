# kyb = Agent Runtime

**日期：** 2026-05-22 晚
**触发：** 阅读 agent runtime 设计文档

## 认知跃迁

> kyb 不是一个 CLI 工具。它是一个 Agent Runtime。

在此之前一直把它当 CLI 工具用——写命令、看输出、处理错误。但它的本质是 runtime：

- 管理 agent 的生命周期
- 提供 memory 和 storage
- 协调通信
- 处理故障

CLI 只是它的接口，不是它的身份。

## 为什么这很重要

这个认知解释了为什么：
- `kyb exec` 的行为和普通 CLI 不同
- 需要 container 抽象而不是进程抽象
- memory 和 CK 是核心设施而不是附加功能

因为它在做 runtime 该做的事。
