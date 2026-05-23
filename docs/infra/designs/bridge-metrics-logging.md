---
decision: 稍后做
---

# Bridge 打点 + 日志系统

桥接链路（飞书→cc-connect→Claude→响应→飞书）目前无端到端延迟和成功率度量。

## 打点环节
1. 消息到达 → 2. 入队处理 → 3. Claude 开始 → 4. Claude 结束 → 5. 消息发出

## 指标体系
- messages_received_total (counter)
- messages_processed_total (counter, status维度)
- turn_duration_seconds (histogram, P50/P90/P99)
- tokens_per_turn (histogram, input/output)
- errors_total (counter, error_type维度)
- active_sessions (gauge)

## 日志
cc-connect 已有结构化 key=value 日志，Vector 解析入 CK。

## Grafana
延迟趋势图、错误率、吞吐量。
