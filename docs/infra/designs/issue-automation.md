---
decision: 现在就做
---

# Issue 自动化通知

用户创建 GitLab issue 后 kyb-infra-boss 无自动感知，需手动查。

## 推荐方案：cc-connect cron 集成

在 cc-connect 内注册 cron：
```
cc-connect cron add --cron "*/10 * * * *" --exec "sh check-issues.sh" --desc "GitLab Issue Tracker"
```

check-issues.sh 用 curl 调 GitLab API，对比 last_issue_id，新 issue 用 `cc-connect send` 发飞书通知。

## 通知格式
飞书群消息：🆕 GitLab Issue #N: title / Labels / Author / Link

## 备选方案
- A: kyb-gl-issue-watch 脚本轮询（独立 crontab）
- B: GitLab Webhook（需公网 HTTP endpoint）
- C: cc-connect cron（推荐，零新增基础设施）

## 对比
| 方案 | 基础设施 | 实时性 | 维护成本 |
|------|----------|--------|----------|
| A: 脚本 | crontab | 分钟级 | 低 |
| B: Webhook | HTTP endpoint | 秒级 | 中 |
| C: cc-connect cron | 无 | 分钟级 | 最低 |

推荐 C：cc-connect 已在运行，cc-connect send 天然打通飞书。
