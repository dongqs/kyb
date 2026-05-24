#!/bin/bash
# 测试飞书 API 各端点
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cd "$SCRIPT_DIR/../.."
source .env 2>/dev/null || true
: "${FEISHU_APP_ID:?需设置 FEISHU_APP_ID}"
: "${FEISHU_APP_SECRET:?需设置 FEISHU_APP_SECRET}"

PROXY="${ALL_PROXY:-socks5://host.docker.internal:2080}"
CHAT_ID="${FEISHU_CHAT_ID:-oc_9b1a09bbdd80887acd63cc02626618c6}"
MODE="${1:-all}"

echo "=== Feishu API 测试 ==="
echo "Chat ID: $CHAT_ID | Mode: $MODE"
echo "(默认跳过 send，用 test_feishu_api.sh send 显式发送)"

feishu_token() {
  curl -s -x "$PROXY" -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
    -H "Content-Type: application/json" \
    -d "{\"app_id\":\"$FEISHU_APP_ID\",\"app_secret\":\"$FEISHU_APP_SECRET\"}" |
    python3 -c "import sys,json;d=json.load(sys.stdin);assert d['code']==0;print(d['tenant_access_token'])"
}

if [ "$MODE" = "auth" ] || [ "$MODE" = "all" ]; then
  echo "--- Token ---"
  TOKEN=$(feishu_token 2>&1) && echo "  ✅ ${TOKEN:0:10}..." || { echo "  ❌ $TOKEN"; exit 1; }
fi

if [ "$MODE" = "send" ]; then
  echo "--- 发送 ---"
  TOKEN=${TOKEN:-$(feishu_token)}
  TS=$(date +%s)
  CODE=$(curl -s -x "$PROXY" -X POST "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"receive_id\":\"$CHAT_ID\",\"msg_type\":\"text\",\"content\":\"{\\\"text\\\":\\\"🧪 $TS\\\"}\"}" |
    python3 -c "import sys,json;print(json.load(sys.stdin)['code'])")
  assert_eq "0" "$CODE" "发送" || exit 1
fi

if [ "$MODE" = "poll" ] || [ "$MODE" = "all" ]; then
  echo "--- 轮询 ---"
  TOKEN=${TOKEN:-$(feishu_token)}
  RESULT=$(curl -s -x "$PROXY" \
    "https://open.feishu.cn/open-apis/im/v1/messages?container_id_type=chat&container_id=$CHAT_ID&page_size=3&sort_type=ByCreateTimeDesc" \
    -H "Authorization: Bearer $TOKEN")
  echo "$RESULT" | python3 -c "
import sys,json;d=json.load(sys.stdin)
for m in d.get('data',{}).get('items',[])[:3]:
  s=m.get('sender',{}).get('id','?')[:16]
  b=m.get('body',{}).get('content','')[:60]
  print(f'  [{m.get(\"msg_type\",\"?\")}] {s}: {b}')
" && echo "  ✅ 轮询成功"
fi

echo ""
echo "=== 全部通过 ==="
