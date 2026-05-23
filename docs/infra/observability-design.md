# 可观测性设计方案汇总

## 1. Bridge 可观测性

### 方案 A：cc-connect 消息全量入 ClickHouse
**采集链路**: cc-connect (docker logs stdout) → Vector 容器 → ClickHouse → Grafana
**CK 表**: `cc.message_log`，字段包括 event_time, event_type, trace_id, message_id, sender_id, content_text, response_len, turn_duration, input_tokens, output_tokens
**Grafana 面板**: 消息概览、响应延迟、用户活跃度、Token 消耗
**存储估算**: 日均 ~34KB，90天 ~3MB

### 方案 B：打点 + 日志系统
**打点环节**: 消息到达→入队→Claude 开始→Claude 结束→消息发出
**指标体系**: P50/P90/P99 延迟、成功率、错误率、吞吐量
**错误分类**: token 过期、网络超时、Claude 崩溃、权限拒绝

### 方案 C：Hook 系统 + 告警
**触发点**: 消息收到、Claude 响应、超时、崩溃、session 恢复、权限请求
**告警规则**: 消息延迟 >30s、Claude 无响应 >5min、cc-connect 进程崩溃、飞书 token 获取失败
**通知渠道**: 飞书群消息 + 巡检系统集成
**自愈**: cc-healthcheck 自动重启 + 心跳监控

## 2. MCP 全流程可观测性
（待补充细节——cc-connect 无原生 MCP 支持，MCP 不在 bridge 路径中）

## 3. Issue 自动化

### 方案 A：`kyb-gl-issue-watch` 脚本轮询
- `~/.kyb/bin/kyb-gl-issue-watch`
- 用 `glab issue list` 定期检查新 issue
- 有变化 → 飞书通知 + pending 文件
- 集成到 feishu-bridge 循环或独立 crontab

### 方案 B：GitLab Webhook
- GitLab 项目配置 webhook，监听 issues events
- 需要公网可达的 HTTP endpoint（新增轻量容器或 nginx 代理）

### 方案 C：cc-connect cron 集成
- 用 `cc-connect cron add --exec` 执行 curl 调 GitLab API
- 通过 `cc-connect send` 发飞书通知
- 不新增基础设施，推荐方案

### 推荐：方案 C
cc-connect cron + curl 调 GitLab API + cc-connect send = 零新增基础设施。
