---
decision: 不应该做
---

# Hook 系统 + 告警

cc-connect 无原生 hook 机制，需构建独立 hook 引擎。

## Hook 触发点
1. 消息收到 2. Claude 响应完成 3. 处理超时 4. Claude 崩溃 5. Session 恢复 6. 权限请求

## 告警规则
| 规则 | 级别 | 条件 |
|------|------|------|
| 消息延迟高 | P2 | turn_duration > 30s 持续 5min |
| Claude 无响应 | P1 | 连续 3 条无 response |
| cc-connect 崩溃 | P0 | container unhealthy |
| Token 失效 | P1 | 飞书 API token 刷新失败 |
| 权限滞留 | P2 | 权限请求 10min 未响应 |

## 自愈
cc-healthcheck 巡检自动检查 cc-connect，unhealthy → docker restart。

## 巡检集成
5min 巡检增加 cc-connect 专项检查。
