# 6 项基建改进

**日期：** 2026-05-22
**模式：** 全部 dispatch，没有一行是亲自写的

## 项目

| # | 改进 | 原因 |
|---|------|------|
| 1 | **Base image 升级** — Go 1.26, Rust 1.95, Python 3.11 | Python 3.10 是昨天 data-ant 踩过的坑，今天彻底解决 |
| 2 | **CK agent_events 表上线** | ClickHouse 中的 agent 事件表 |
| 3 | **kyb morning 命令** | 一键执行晨间检查 |
| 4 | **自动 metrics** | 容器级 CPU/内存/磁盘自动采集，不用再手动 `docker stats` |
| 5 | **Shellwords.escape 全局注入修复** | 昨天 check.rb 发现同类漏洞，今天全局修 |
| 6 | **rm cname bug 修复** | 传 container name 而非 ID 时报错 |

## 意义

一天 6 项，全 dispatch。这是"超过 1 秒就派人"原则的实战证明——不需要自己写，只需要知道要做什么。
