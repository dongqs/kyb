# 2026-05-27 — 架构 evolution 05：重要决策

原始文件：`architecturer/evolution/05-decisions.md`

**D1 砍 Worktree：** agent 被 git worktree 卡死。选砍需求（B）不是加文档（A）。砍掉 worktree+sandbox，默认 mount。代码减少，测试全绿。原则：砍需求比加功能难 10 倍但效果好 10 倍。

**D2 不去 Go：** 部署麻烦想 Go 重写（13-16 天零增长）。选 Tebako 打单文件二进制。保住了零 gem 依赖的 Ruby 代码。原则：不要为"现代感"重写工作系统。

**D3 不加 Kafka：** Vector→CK 还是 Vector→Kafka→CK。3 专家独立分析：当前量级不需要。原则：不要为还没出现的问题做架构。

**D4 不造 hooks：** 发现 cc-connect v1.3.2 已有原生 hooks，直接用。省了整个 hook engine。原则：买/用 vs 造需要专门去验证。

**D5 IaC：** 48 面板 + 7 告警规则全部写代码部署。容器重建后自动恢复。这不是选择，是自愈的前提。
