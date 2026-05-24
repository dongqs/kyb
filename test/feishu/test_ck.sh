#!/bin/bash
# 测试 CK 写入和读取
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "=== 1. CK 连通性 ==="
ck_query "SELECT 1" > /dev/null && echo "  ✅ CK 可达" || { echo "  ❌ CK 不可达"; exit 1; }

echo ""
echo "=== 2. 写入测试事件 ==="
TS=$(utc_now)
ck_query "
  INSERT INTO kyb.agent_events (timestamp, agent_id, session_id, project, event_type, content, tags)
  VALUES ('${TS}', 'test-script', 'test-ck-$$', 'kyb', 'test_write', 'CK 写入测试 from test_ck.sh', {})
" && echo "  ✅ 写入成功" || { echo "  ❌ 写入失败"; exit 1; }

echo ""
echo "=== 3. 读取测试事件 ==="
ck_query "
  SELECT timestamp, event_type, content
  FROM kyb.agent_events
  WHERE agent_id = 'test-script' AND session_id = 'test-ck-$$'
  ORDER BY timestamp DESC LIMIT 5 FORMAT PrettyCompact
" && echo "  ✅ 读取成功" || { echo "  ❌ 读取失败"; exit 1; }

echo ""
echo "=== 全部通过 ==="
