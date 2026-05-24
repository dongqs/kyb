#!/bin/bash
# 检查是否有新的飞书 @消息
# 记录上次检查的时间戳，增量查询 CK
# 用法: ./check_new.sh
set -euo pipefail

LAST_CHECK_FILE="/tmp/feishu-last-check"
CK_HOST="${CLICKHOUSE_HOST:-host.orb.internal}"

# 上次检查时间（默认 5 分钟前）
if [ -f "$LAST_CHECK_FILE" ]; then
  SINCE=$(cat "$LAST_CHECK_FILE")
else
  SINCE=$(date -u -d '5 minutes ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null ||
          date -u -v-5M '+%Y-%m-%d %H:%M:%S' 2>/dev/null ||
          echo "1970-01-01 00:00:00")
fi

NOW=$(date -u '+%Y-%m-%d %H:%M:%S')
echo "$NOW" > "$LAST_CHECK_FILE"

# 查 CK 中是否有新的消息（所有类型，不仅是 @）
RESULT=$(clickhouse-client --host "$CK_HOST" --query "
  SELECT timestamp, event_type, content
  FROM kyb.agent_events
  WHERE agent_id = 'feishu-bot'
    AND (event_type = 'message_mention' OR event_type = 'message_new')
    AND timestamp > '$SINCE'
  ORDER BY timestamp DESC
  FORMAT PrettyCompact
" 2>/dev/null)

if [ -n "$RESULT" ]; then
  COUNT=$(echo "$RESULT" | grep -cE 'message_mention|message_new' || true)
  echo ""
  echo "╔══ 飞书新消息 ═══════════════════════════"
  echo "║ 上次检查: $SINCE"
  echo "║ 新消息数: $COUNT"
  echo "║"
  echo "$RESULT" | while IFS= read -r line; do
    echo "║ $line"
  done
  echo "╚══════════════════════════════════════════"
  echo ""
  echo "回复命令: cd ~/projects/kyb && export \$(grep -v '^#' .env | xargs) &&"
  echo "  ALL_PROXY=socks5://host.docker.internal:2080 ./bin/feishu-reply \"你的回复\""
else
  echo "无新消息"
fi
