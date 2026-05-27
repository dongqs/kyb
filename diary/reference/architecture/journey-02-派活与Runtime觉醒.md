# 2026-05-27 — 架构 journey 02：派活与 Runtime 觉醒

原始文件：`architecturer/journey/02-growing-pains.md` — 2026-05-22 Day 2

**关键词：** 被纠正七八次、CI 红一天的根因找到、六项基建同时上线、Runtime 觉醒。

**CI 五路围攻：** master 红一天查不到原因 → 开五个不同世界观的 agent。第一性原理 5 分钟找到根因：`Kyb.in_container?` 在 CI 误判。世界观多样性 > 数量。

**六项基建零行代码：** Base image 更新、CK agent_events、kyb morning、自动 metrics、Shellwords.escape、rm cname 修复——没有一行是自己写的。

**认知跃迁：** kyb 不是 CLI 是 Agent Runtime。之前当 CLI 写，但它做的事是 runtime 的事。

**先关反馈回路再搭架构：** 测试坏了先修，CI 红了先查，底层堵住了再往上搭。控制论先于系统论。

**记忆分层诞生：** 金鱼脑子(5s) → Memory(3h) → CK(30d) → 文档(永久)。每遇到一个问题加一层。
