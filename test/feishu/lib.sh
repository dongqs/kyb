# feishu test lib — 公共函数
# source 到各测试脚本中，避免重复代码
# 用法: source "$(dirname "$0")/lib.sh"

# === CK 查询 ===
ck_query() {
  clickhouse-client --host "${CLICKHOUSE_HOST:-host.orb.internal}" --query "$1" 2>/dev/null || true
}

ck_count() {
  local result
  result=$(ck_query "$1")
  echo "${result:-0}" | tr -d '[:space:]'
}

# === CK 时间计算 ===
utc_now() {
  date -u '+%Y-%m-%d %H:%M:%S'
}

utc_ago() {
  local mins=$1
  date -u -d "${mins} minutes ago" '+%Y-%m-%d %H:%M:%S' 2>/dev/null ||
  date -u -v-${mins}M '+%Y-%m-%d %H:%M:%S' 2>/dev/null ||
  echo "1970-01-01 00:00:00"
}

# === 上次检查时间管理 ===
last_check_read() {
  local file=$1 default_ago=$2
  if [ -f "$file" ]; then
    cat "$file"
  else
    utc_ago "$default_ago"
  fi
}

last_check_write() {
  local file=$1
  utc_now > "$file"
}

# === 时间比较（字符串级，避免 date -d 兼容性问题）===
time_is_recent() {
  local check_time=$1 max_minutes=$2
  local ago
  ago=$(utc_ago "$max_minutes")
  [ "$(echo "$check_time" | tr -d '[:space:]')" \> "$(echo "$ago" | tr -d '[:space:]')" ] 2>/dev/null
}

# === 断言 ===
assert_eq() {
  local expected=$1 actual=$2 label=${3:-''}
  if [ "$expected" != "$actual" ]; then
    echo "  ❌ $label: 期望=$expected 实际=$actual"
    return 1
  else
    echo "  ✅ $label"
  fi
}

assert_nz() {
  local val=$1 label=${2:-''}
  if [ -z "$val" ]; then
    echo "  ❌ $label: 为空"
    return 1
  else
    echo "  ✅ $label"
  fi
}
