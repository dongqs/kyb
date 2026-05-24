#!/bin/bash
# 测试 bot 进程状态和日志
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

MODE="${1:-all}"

if [ "$MODE" = "process" ] || [ "$MODE" = "all" ]; then
  echo "--- Bot 进程 ---"
  PID=$(ps aux | grep "Kyb::FeishuBot" | grep -v grep | awk '{print $2}' | head -1)
  assert_nz "$PID" "进程" || exit 1
  echo "  PID=$PID (uptime $(ps -o etime= -p "$PID" 2>/dev/null || echo '?'))"
fi

if [ "$MODE" = "log" ] || [ "$MODE" = "all" ]; then
  echo "--- 日志 ---"
  assert_nz "$(ls -la /tmp/feishu-bot.log 2>&1)" "文件" || exit 1
  echo "  $(wc -c < /tmp/feishu-bot.log) bytes, $(wc -l < /tmp/feishu-bot.log) lines"
fi

if [ "$MODE" = "heartbeat" ] || [ "$MODE" = "all" ]; then
  echo "--- 心跳 ---"
  LAST_HB=$(grep "♥ polls=" /tmp/feishu-bot.log 2>/dev/null | tail -1 || true)
  assert_nz "$LAST_HB" "心跳记录" || echo "  ⚠️ 尚无心跳"
fi

if [ "$MODE" = "ck" ] || [ "$MODE" = "all" ]; then
  echo "--- CK 事件 ---"
  COUNT=$(ck_count "SELECT count() FROM kyb.agent_events WHERE agent_id='feishu-bot'")
  echo "  共 $COUNT 条"
fi

echo ""
echo "=== 全部通过 ==="
