#!/bin/bash
# 30 分钟详检 — bot 健康 + 消息统计 + 错误率
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SINCE=$(last_check_read "/tmp/feishu-last-check-30m" 35)
last_check_write "/tmp/feishu-last-check-30m"

echo "╔══ 飞书 bot 状态报告 ═══════════════"

# Bot 进程
BOT_PID=$(ps aux | grep "Kyb::FeishuBot" | grep -v grep | awk '{print $2}' | head -1)
if [ -n "$BOT_PID" ]; then
  UPTIME=$(ps -o etime= -p "$BOT_PID" 2>/dev/null || echo "?")
  echo "║ Bot: PID $BOT_PID 运行中 (uptime $UPTIME)"
else
  echo "║ Bot: ❌ 未运行"
fi

# 心跳检测
LAST_HB=$(ck_query "
  SELECT max(timestamp) FROM kyb.agent_events
  WHERE agent_id='feishu-bot' AND event_type='heartbeat'
")
if [ -n "$LAST_HB" ] && [ "$LAST_HB" != "0" ]; then
  if time_is_recent "$LAST_HB" 5 2>/dev/null; then
    echo "║ ♥ 心跳正常"
  else
    echo "║ ⚠️ 心跳 >5 分钟前: $LAST_HB"
  fi
else
  echo "║ ⚠️ 尚无心跳记录"
fi

# 事件统计
STATS=$(ck_query "
  SELECT event_type, count()
  FROM kyb.agent_events
  WHERE agent_id='feishu-bot' AND timestamp > '$SINCE'
  GROUP BY event_type ORDER BY count() DESC FORMAT TSVWithNames
")
if [ -n "$STATS" ]; then
  echo "║ 近 30 分钟事件:"
  echo "$STATS" | while IFS=$'\t' read -r evt cnt; do
    [ "$evt" = "event_type" ] && continue; [ -z "$evt" ] && continue
    printf "║   %-20s %s\n" "$evt" "$cnt"
  done
fi

# 错误
ERR_COUNT=$(ck_count "
  SELECT count() FROM kyb.agent_events
  WHERE agent_id='feishu-bot' AND event_type='bot_error' AND timestamp > '$SINCE'
")
if [ "${ERR_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  echo "║ ❌ 错误事件: $ERR_COUNT"
fi

echo "║"
echo "║ 💡 飞书消息记得用飞书回！"
echo "╚══════════════════════════════════════"
