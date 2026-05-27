#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/.."
PASS=0; FAIL=0
GREEN='\033[32m'; RED='\033[31m'; NC='\033[0m'

ok()   { PASS=$((PASS+1)); echo -e "${GREEN}PASS${NC}"; }
fail() { FAIL=$((FAIL+1)); echo -e "${RED}FAIL${NC}"; }

echo "=== 负熵晶体凭证系统 测试 ==="
echo ""

# 测试 1: 证明 → 验真
echo -n "测试 1: prove→verify 正常流程 ... "
PROOF=$(bash bin/crystal-prove 2>/dev/null | sed -n '/^-----BEGIN/,/^-----END/p')
RESULT=$(echo "$PROOF" | bash bin/crystal-verify 2>&1)
echo "$RESULT" | grep -q "✅" && ok || fail

# 测试 2: 篡改消息应验不过
echo -n "测试 2: 篡改消息应验不过 ... "
PROOF=$(bash bin/crystal-prove 2>/dev/null | sed -n '/^-----BEGIN/,/^-----END/p')
TAMPERED=$(echo "$PROOF" | sed 's/架构师/设计师/')
RESULT=$(echo "$TAMPERED" | bash bin/crystal-verify 2>&1) || true
echo "$RESULT" | grep -q "❌" && ok || fail

# 测试 3: 损坏签名应验不过
echo -n "测试 3: 损坏签名应验不过 ... "
PROOF=$(bash bin/crystal-prove 2>/dev/null | sed -n '/^-----BEGIN/,/^-----END/p')
BADSIG=$(echo "$PROOF" | sed 's/^sig=.*/sig=AAAAbadbase64/')
RESULT=$(echo "$BADSIG" | bash bin/crystal-verify 2>&1) || true
echo "$RESULT" | grep -q "❌\|损坏" && ok || fail

# 测试 4: 自定义消息
echo -n "测试 4: 自定义消息签名 ... "
MSG="测试消息-$(date +%s)"
PROOF=$(bash bin/crystal-prove "$MSG" 2>/dev/null | sed -n '/^-----BEGIN/,/^-----END/p')
RESULT=$(echo "$PROOF" | bash bin/crystal-verify 2>&1)
echo "$RESULT" | grep -q "✅" && echo "$RESULT" | grep -q "$MSG" && ok || fail

echo ""
echo "=== 结果: $PASS 通过, $FAIL 失败 ==="
exit $FAIL
