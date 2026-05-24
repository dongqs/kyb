# 操作系统哲学

## kyb = Agent Runtime

> kyb 不是一个 CLI 工具。它是一个 Agent Runtime。

CLI 只是它的接口，不是它的身份。

Runtime 要做的事：
- 管理 agent 的生命周期（create, enter, exec, rm）
- 提供记忆系统（memory 3h, CK 30d, 文档永久）
- 协调通信（飞书桥、hooks、巡检）
- 处理故障（autossh、--init、内存限制）

## 金鱼脑子哲学

> "我们都是金鱼脑子只能记5秒 memory能记3小时 ck让我们能记30天 文档可以传给下一代"

| 层 | 持久度 | 载体 |
|----|--------|------|
| 金鱼脑子 | 5 秒 | 模型上下文 |
| Memory | 3 小时 | session 短期 |
| ClickHouse | 30 天 | agent 事件表 |
| 文档 | 永久 | .md 文件 |

第四层（文档）最难。因为写文档要主动、要结构化、要花时间。但它是唯一能传给下一代的。

## 单一代码库

Go 重写被否决。Tebako 二进制打包被采纳。

**Ruby 已是零依赖（仅 stdlib）。** 不要为了技术栈的"现代感"而引入重写风险。在 Agent Runtime 的场景下，Ruby 的 expressiveness 是资产而非负债。
