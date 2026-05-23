#!/bin/bash
# Feishu event monitor - runs continuously, polls for new events and notifies
EVENTS_DIR=/tmp/feishu-events
SEEN_FILE=/tmp/feishu-seen
TARGET_SESSION="${TMUX_TARGET_SESSION:-dev}"

# Source user ID to display name mappings
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../conf/feishu-users.sh"

# Initialize
mkdir -p "$EVENTS_DIR"
ls "$EVENTS_DIR"/*.json 2>/dev/null | wc -l > "$SEEN_FILE" 2>/dev/null || echo 0 > "$SEEN_FILE"

echo "[monitor] started at $(date '+%Y-%m-%d %H:%M:%S')"
echo "[monitor] watching $EVENTS_DIR"

LAST_CHECK=0

while true; do
  CURRENT=$(ls "$EVENTS_DIR"/*.json 2>/dev/null | wc -l)
  SEEN=$(cat "$SEEN_FILE" 2>/dev/null || echo 0)

  if [ "$CURRENT" -gt "$SEEN" ] && [ "$CURRENT" -gt 0 ]; then
    NEW=$((CURRENT - SEEN))
    echo "$CURRENT" > "$SEEN_FILE"

    # Process each new event (from oldest new to newest)
    ls -t "$EVENTS_DIR"/*.json 2>/dev/null | head -"$NEW" | while read -r LATEST; do
      CONTENT=$(python3 -c "
import sys,json
d=json.load(open(sys.argv[1]))
print(d.get('content','?')[:200])
" "$LATEST" 2>/dev/null)

      SENDER_ID=$(python3 -c "
import sys,json
d=json.load(open(sys.argv[1]))
print(d.get('sender_id','?'))
" "$LATEST" 2>/dev/null)

      MSG_TYPE=$(python3 -c "
import sys,json
d=json.load(open(sys.argv[1]))
print(d.get('message_type','?'))
" "$LATEST" 2>/dev/null)

      NAME="${FEISHU_USERS[$SENDER_ID]:-$SENDER_ID}"
      NAME="${NAME:0:16}"

      MSG="[飞书][${NAME}] ${CONTENT}"
      echo "$MSG" | tee -a /tmp/feishu-notifications.log

      # Notify the target tmux session
      if tmux has-session -t "$TARGET_SESSION" 2>/dev/null; then
        tmux display-message -t "$TARGET_SESSION" "$MSG" 2>/dev/null || true
      fi
    done
  fi

  sleep 3
done
