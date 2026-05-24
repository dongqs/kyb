#!/bin/bash
# 1 分钟快检 — 只看有没有新消息（最轻量）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SINCE=$(last_check_read "/tmp/feishu-last-check-1m" 2)
last_check_write "/tmp/feishu-last-check-1m"

COUNT=$(ck_count "
  SELECT count() FROM kyb.agent_events
  WHERE agent_id='feishu-bot'
    AND (event_type='message_mention' OR event_type='message_new')
    AND timestamp > '$SINCE'
")

if [ "$COUNT" -gt 0 ] 2>/dev/null; then
  echo "飞书有 $COUNT 条新消息"
fi
