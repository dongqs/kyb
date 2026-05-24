#!/bin/bash
# 10 分钟中检 — 新消息一览 + 心跳健康
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SINCE=$(last_check_read "/tmp/feishu-last-check-10m" 15)
last_check_write "/tmp/feishu-last-check-10m"

# 心跳检测
LAST_HB=$(ck_query "
  SELECT max(timestamp) FROM kyb.agent_events
  WHERE agent_id='feishu-bot' AND event_type='heartbeat'
")
if [ -n "$LAST_HB" ] && [ "$LAST_HB" != "never" ] && [ "$LAST_HB" != "0" ]; then
  echo "♥ 上次心跳: $LAST_HB"
fi

# 消息一览
RESULT=$(ck_query "
  SELECT timestamp, event_type, content
  FROM kyb.agent_events
  WHERE agent_id='feishu-bot'
    AND (event_type='message_mention' OR event_type='message_new')
    AND timestamp > '$SINCE'
  ORDER BY timestamp DESC
  FORMAT TSVWithNames
")
if [ -n "$RESULT" ]; then
  echo "$RESULT" | while IFS=$'\t' read -r ts evt content; do
    [ -z "$ts" ] && continue
    [ "$ts" = "timestamp" ] && continue
    echo "  [${evt}] $(echo "$content" | head -c 120)"
  done
fi

echo "# 飞书消息记得用飞书回"
