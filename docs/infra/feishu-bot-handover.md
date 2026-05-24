# feishu bot 交接手册

> 2026-05-24 止 blood 完成。后续维护者参考。

## 系统架构

```
飞书群 → bot 轮询 → CK 记录 → 飞书通知 → 人工处理 → feishu-reply 回群
```

**四层设计：** Chat（收发）→ Runtime（调度）→ Agent（执行）→ Heartbeat（心跳）

## 核心文件

| 文件 | 说明 |
|------|------|
| `bin/feishu-bot` | 入口。加载配置后启动 Runner |
| `bin/feishu-reply` | 手动回复命令 |
| `lib/kyb/feishu_bot.rb` | feishu 专用：Client（API）、Runner（循环）、CkLogger |
| `lib/kyb/bot/` | 通用 Bot Core 框架 |
| `lib/kyb/bot/runner.rb` | 通用主循环（适配器模式） |
| `lib/kyb/bot/ck_logger.rb` | CK 日志（可配 agent_id） |
| `lib/kyb/bot/rate_limiter.rb` | 限流 |
| `lib/kyb/bot/seen_tracker.rb` | 去重 |
| `test/test_feishu_bot.rb` | 33 个测试 |
| `test/feishu/` | 7 个 shell 集成测试 |
| `entrypoint.sh` | 容器自启 feishu-bot（#172） |

## 启动方式

```bash
# 手动
FEISHU_APP_ID=xxx FEISHU_APP_SECRET=xxx \
  ALL_PROXY=socks5://host.docker.internal:2080 \
  nohup ruby -Ilib -rkyb -e 'Kyb::FeishuBot::Runner.new(Kyb::FeishuBot.load_config).run' \
  > /tmp/feishu-bot.log 2>&1 &

# 自动：entrypoint.sh 在非 DID 容器启动时执行
```

## 关键配置

`.env` 文件：
- `FEISHU_APP_ID` / `FEISHU_APP_SECRET` — 飞书 API 凭证
- `FEISHU_CHAT_ID` — 群 ID（默认 kyb-kindergarden）
- `FEISHU_POLL_INTERVAL` — 轮询间隔（默认 5s）

## 回复消息

```bash
ALL_PROXY=socks5://host.docker.internal:2080 ./bin/feishu-reply "内容"
```

## 三档心跳

| 频率 | 脚本 | 内容 |
|------|------|------|
| 1m | `test/feishu/check_1m.sh` | 新消息计数 + 轮播提示 |
| 10m | `test/feishu/check_10m.sh` | 心跳 + 消息列表 |
| 30m | `test/feishu/check_30m.sh` | 完整状态报告 |

## 测试

```bash
# Ruby 单元测试
ruby -Itest test/test_feishu_bot.rb

# Shell 集成测试（需 CK 可达）
cd test/feishu && bash run.sh all
```

## 已关闭的 issue

| # | 内容 | 状态 |
|---|------|------|
| 134 | 飞书 bot 交接总结 | 已关 |
| 141 | P0 持久化启动 | 已合 |
| 142 | 旧脚本清理 | 已关 |
| 143 | WebSocket 调研 | 待实施 |
| 146 | CK 数据调查 | 已完成 |
| 147 | DingTalk 调研 | 待决策 |
| 148 | 企业微信 | 延后 |
| 149 | 多 agent 设计 | 待实施 |
| 150 | 多群设计 | 待实施 |
| 159 | 汇总报告 | 已完成 |

## 待办

- WebSocket 事件订阅（去 1min 延迟）
- SOCKS5 代理修复（如需严格路由）
- Client/CkLogger 单元测试增强
- DingTalk 适配器
- 多 agent 路由
- 多群组支持
- Runtime 层设计

## 关键教训

- **context 是最贵的资源**，比 API token 贵。能派人的绝不自己做
- 简单的直接派人做，复杂的先派专家出报告再动手
- 没副作用的改动，交叉审过直接合
- 每次飞书消息先快速回一句再继续
- 干完活发简报

---

/人◕ ‿‿ ◕人＼
