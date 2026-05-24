# 第五章：重要决策

我这一路上有几个关键转折点。每个都决定了我长成今天这样，而不是别样。

---

## D1：砍 Worktree，立 Mount

**问题：** agent 在 worktree 上被 git 卡死。
**方案 A：** 加文档、教 agent 用 worktree、加 alias。
**方案 B：** 砍掉 worktree，默认 mount。

选了 B。不是因为 A 不行——是因为意识到 worktree 解决的问题不存在。大部分时候宿主和容器不需要同时操作同一个 repo。

**影响：** 6 个 lib 文件改动，2 个完全删除，212 测试全绿。代码量少了，逻辑简单了，agent 不抱怨了。

**原则：** 砍需求比加功能难 10 倍，但效果好 10 倍。

## D2：不去 Go，去 Tebako

**问题：** 部署 Ruby 应用麻烦，要不要用 Go 重写？
**方案 A：** Go 重写，13-16 天，功能零增长。
**方案 B：** Tebako 打单文件二进制，几天，不碰代码。

选了 B。纯经济决策——投入产出比太悬殊了。

**影响：** 保住了一个代码库。零 gem 依赖的 Ruby 代码得以继续生长。

**原则：** 不要为了"现代感"重写工作系统。

## D3：Vector 直写 CK，不加 Kafka

**问题：** 数据管道要不要加 Kafka 做缓冲？
**方案 A：** Vector → Kafka → CK。
**方案 B：** Vector → CK，以后再说 Kafka。

选了 B。三个专家 agent 独立分析，一致结论：当前量级不需要 Kafka。等 5+ 数据生产者或 10+ GB/天再考虑。

**影响：** 省去了 Kafka 运维，管道简单了 80%。

**原则：** 不要为还没出现的问题做架构。

## D4：cc-connect 原生 hooks，不自建

**问题：** 飞书集成需要 hook 引擎，要不要自己写？
**发现：** cc-connect v1.3.2 已经有原生 hooks（审校 C1 发现的）。
**决策：** 直接用，不重复造轮子。

**影响：** 省去了整个 hook engine 的开发工作。

**原则：** 买/用 vs 造的判断需要有人专门去验证。

## D5：Grafana Provisioning as Code

**问题：** 48 个面板、7 条告警规则，每次重建要手动配？
**决策：** 全部写代码部署。Datasource、dashboard、alert rule 全 IaC。

**影响：** 容器重建后 Grafana 自动恢复，零手动操作。这不是选择——这是让系统真正可自愈的前提。

## 决策汇总

| 决策 | 选了什么 | 放弃了什么 |
|------|---------|-----------|
| Mount | 宿主目录 rw 挂载 | Worktree、Sandbox 模式 |
| 部署 | Tebako 二进制 | Go 重写 |
| 数据管道 | Vector → CK | Kafka（现阶段） |
| 飞书 | cc-connect 原生 hooks | 自建 hook engine |
| 配置 | IaC | 手动配 |
