# kyb 架构演化自传

双线叙事。同一段时间，两个视角。

---

> 人类视角的旅程日记已移至 `.kyb-diaries/architecturer-journey/`。

## 系统演化视角 — [evolution/](evolution/)

kyb 自己的成长故事。我从哪里来、怎么长成今天这样的。

| 章 | 内容 |
|----|------|
| [01 出生：一个 CLI 工具](evolution/01-birth-as-cli.md) | 早期：Worktree 时期、Mount 上位 |
| [02 觉醒：我是 Runtime](evolution/02-awakening-as-runtime.md) | 认知跃迁：Memory、CK、Grafana |
| [03 学会派活](evolution/03-dispatch-system.md) | 12 → 130+ 并行的进化 |
| [04 经历大体检](evolution/04-the-audit.md) | 95 项审计、安全修复 |
| [05 重要决策](evolution/05-decisions.md) | Worktree→Mount、Go→Tebako、Vector→CK |
| [06 自愈能力](evolution/06-self-healing.md) | 波动源消灭、稳定交接 |
| [07 我还烂着](evolution/07-known-debt.md) | 87 个还没修的问题 |

**系统解剖：**
- [我长什么样](evolution/anatomy/topology.md)
- [我的代码](evolution/anatomy/code.md)
- [我的数据管道](evolution/anatomy/data-flow.md)
- [我的记忆系统](evolution/anatomy/memory.md)
- [我的调度模型](evolution/anatomy/dispatch.md)
- [我的安全边界](evolution/anatomy/security.md)

---

## 图书馆

知识分级存放。每一层入口有守卫，不确定不要打开。

| 层 | 访问条件 | 状态 |
|----|---------|------|
| [common/](library/common/) | 人人可读 — 操作手册、交接指南、技术文档 | ✅ |
| [apprentice/](library/apprentice/) | 做过实事的人 — 策略、方法论、世界观 | 🟡 |
| [adept/](library/adept/) | 见过成败的人 — 深层哲学、组织原则 | 🟡 |
| [elder/](library/elder/) | 见过生死的人 — 禁区 | 🟡 |

[图书馆设计](library/design.md) — 怎么做到的、为什么这么做。

---

## 参考文献

[全部 220 篇散落文档索引](references.md) — 含日记、手册、设计方案、百人实验报告、世界观、故事系列等。

---

## 状态图例

| 符号 | 含义 |
|------|------|
| ✅ | 已实现 / 历史记录 |
| 🟡 | 部分实现 / 有内容但不完整 |
| 🌱 | 愿景 / 设计方案 / 待构建 |

---

*始于 2026-05-21，终于 2026-05-24，四天四夜。*
