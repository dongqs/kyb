#!/bin/bash
# feishu 测试套件 — 每一步独立可测
# 用法: ./run.sh [test_name]
#
# 可用测试:
#   ck         - CK 写入/读取
#   api        - Feishu API 认证/发送/轮询
#   bot        - Bot 进程/日志/心跳
#   check-1m   - 1 分钟快检（有新消息?）
#   check-10m  - 10 分钟中检（消息列表）
#   check-30m  - 30 分钟详检（完整状态）
#   all        - 全部运行
#
# 新增测试请在此注册
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p /tmp/feishu-test-logs

run_test() {
  local name=$1 script=$2
  echo ""
  echo "╔══ 测试: $name ═══════════════════════════"
  LOG="/tmp/feishu-test-logs/${name}.log"
  if bash "$script" 2>&1 | tee "$LOG"; then
    echo "╚══ ✅ $name 通过 ═══════════════════════════"
    return 0
  else
    echo "╚══ ❌ $name 失败 (log: $LOG) ═══════════"
    return 1
  fi
}

case "${1:-all}" in
  ck)
    run_test "ck" "./test_ck.sh"
    ;;
  api)
    run_test "feishu_api" "./test_feishu_api.sh"
    ;;
  bot)
    run_test "bot_status" "./test_bot_status.sh"
    ;;
  check-1m)
    run_test "check_1m" "./check_1m.sh"
    ;;
  check-10m)
    run_test "check_10m" "./check_10m.sh"
    ;;
  check-30m)
    run_test "check_30m" "./check_30m.sh"
    ;;
  all)
    echo "╔══════════════════════════════════════════╗"
    echo "║        feishu 全部测试                   ║"
    echo "╚══════════════════════════════════════════╝"
    FAILED=0
    run_test "ck" "./test_ck.sh" || ((FAILED++))
    run_test "feishu_api" "./test_feishu_api.sh" || ((FAILED++))
    run_test "bot_status" "./test_bot_status.sh" || ((FAILED++))
    run_test "check_1m" "./check_1m.sh" || ((FAILED++))
    run_test "check_10m" "./check_10m.sh" || ((FAILED++))
    run_test "check_30m" "./check_30m.sh" || ((FAILED++))
    echo ""
    if [ "$FAILED" -eq 0 ]; then
      echo "✅ 全部 $FAILED 测试通过"
    else
      echo "❌ $FAILED 个测试失败"
    fi
    exit $FAILED
    ;;
  *)
    echo "用法: $0 [ck|api|bot|check-1m|check-10m|check-30m|all]"
    echo "可用测试:"
    grep -E '^\s+[a-z]+\)' "$0" | grep -v 'all\|*)\|run_test' | sed 's/)/  /'
    exit 1
    ;;
esac
