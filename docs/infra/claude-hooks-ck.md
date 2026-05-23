# Claude Code Hooks -- ClickHouse Telemetry Pipeline

> Send all Claude Code agent activity into ClickHouse for infrastructure observability.
> CK 25.1 at `host.orb.internal:8123` (HTTP) / `:9000` (native), trust auth.

## Table of Contents

1. [Hook Event Reference](#1-hook-event-reference)
2. [Schema Design](#2-schema-design)
3. [Hook Script Templates](#3-hook-script-templates)
4. [settings.json Configuration](#4-settingsjson-configuration)
5. [Proxy Configuration](#5-proxy-configuration)
6. [Testing Hooks](#6-testing-hooks)
7. [Grafana Queries](#7-grafana-queries)
8. [Volume Estimation](#8-volume-estimation)
9. [Error Handling & Fail-Open](#9-error-handling--fail-open)
10. [Comparison with kyb.reporter](#10-comparison-with-kybreporter)

---

## 1. Hook Event Reference

Claude Code 2.1.148 supports the following hook events. Events marked **Blocking** can prevent the tool from executing by exiting non-zero.

### Tool Lifecycle

| Event | Fires | Blocking | Input Highlights |
|-------|-------|----------|------------------|
| `PreToolUse` | Before a tool executes | Yes | `toolName`, `input`, `hopCount` |
| `PostToolUse` | After a tool succeeds | No | `toolName`, `input`, `output`, `durationMs` |
| `PostToolUseFailure` | After a tool fails | No | `toolName`, `input`, `error`, `durationMs` |

### Session Lifecycle

| Event | Fires | Blocking | Input Highlights |
|-------|-------|----------|------------------|
| `SessionStart` | Session begins or resumes | No | `sessionId`, `cwd`, `project`, `version`, `entrypoint` |
| `SessionEnd` | Session terminates | No | `sessionId`, `durationMs`, `messageCount` |
| `Stop` | Claude finishes responding | No | `sessionId`, `stopReason` |
| `UserPromptSubmit` | Before Claude processes your prompt | No | `prompt`, `sessionId` |

### Agent / Subagent

| Event | Fires | Blocking | Input Highlights |
|-------|-------|----------|------------------|
| `SubagentStart` | Subagent is forked | No | `agentId`, `task`, `parentSessionId` |
| `SubagentStop` | Subagent finishes | No | `agentId`, `result`, `durationMs` |

### Context Management

| Event | Fires | Blocking | Input Highlights |
|-------|-------|----------|------------------|
| `PreCompact` | Before context compaction | No | `messageCount`, `tokenCount` |
| `PostCompact` | After context compaction | No | `messageCount`, `tokenCount`, `tokensRemoved` |
| `InstructionsLoaded` | CLAUDE.md / rules loaded | No | `source`, `fileCount` |

### Permissions

| Event | Fires | Blocking | Input Highlights |
|-------|-------|----------|------------------|
| `PermissionRequest` | Permission dialog shown | No | `toolName`, `command`, `reason` |
| `PermissionDenied` | Auto-mode denies a call | No | `toolName`, `command`, `reason` |
| `Notification` | Claude sends notification | No | `message`, `type` |

### File System

| Event | Fires | Blocking | Input Highlights |
|-------|-------|----------|------------------|
| `FileChanged` | Watched file changes on disk | No | `filePath`, `changeType` |
| `CwdChanged` | Working directory changes | No | `previousCwd`, `newCwd` |

> Total: ~28 events. Full list at [code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks)

### Settings.json Format

```json
{
  "hooks": {
    "EventName": [
      {
        "matcher": "ToolPattern",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/hook-script.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

- `matcher`: glob or regex to filter tools (e.g. `"Bash"`, `"Write|Edit"`, `"*"`, `"mcp__.*"`)
- `type`: `"command"` (shell), `"prompt"` (LLM), `"http"` (webhook), `"mcp_tool"`, or `"agent"`
- `timeout`: max seconds before hook is killed (default 60, 30 for `UserPromptSubmit`)
- `once`: if `true`, runs only once per session

### Environment Variables Available to Hooks

| Variable | Description | Example |
|----------|-------------|---------|
| `CLAUDE_PROJECT_DIR` | Project root directory | `/home/dev/projects/kyb` |
| `CLAUDE_FILE_PATH` | File being edited/read | `/home/dev/projects/kyb/lib/foo.rb` |
| `CLAUDE_BASH_COMMAND` | Bash command being run | `git status` |
| `CLAUDE_SESSION_ID` | Current session ID | `faab8111-9c5c-4c22-88c9-da5cedd05faf` |
| `CLAUDE_HOOK_EVENT` | Event name | `PostToolUse` |

### Hook Stdin Contract

Hooks receive a JSON payload on stdin with the event's data:

```json
{
  "event": "PostToolUse",
  "sessionId": "faab8111-...",
  "toolName": "Bash",
  "input": { "command": "git status" },
  "output": { "exitCode": 0, "stdout": "...", "stderr": "" },
  "durationMs": 1234,
  "timestamp": "2026-05-22T12:00:00.000Z"
}
```

---

## 2. Schema Design

### Core table: `kyb.claude_hook_events`

Structured columns for efficient querying, not raw JSON blob:

```sql
CREATE TABLE kyb.claude_hook_events (
    timestamp DateTime64(3),
    event_type LowCardinality(String),
    session_id String,
    agent_id LowCardinality(String),
    cwd String,
    project String,

    -- Tool execution
    tool_name LowCardinality(String),
    tool_input String,
    tool_output String,
    tool_exit_code Nullable(Int32),
    duration_ms UInt32,
    error_message String,

    -- Session
    claude_version LowCardinality(String),
    entrypoint LowCardinality(String),   -- cli, agent
    is_interactive Bool,
    model String,

    -- Subagent
    parent_session_id String,
    subagent_task String,

    -- Prompt
    prompt_preview String,

    -- Resource usage
    token_count UInt32,
    message_count UInt32,

    -- Proxy
    via_proxy Bool DEFAULT false,

    -- Flexible metadata
    metadata Map(String, String)
)
ENGINE = MergeTree
ORDER BY (toDate(timestamp), project, event_type, session_id)
TTL timestamp + INTERVAL 30 DAY
SETTINGS index_granularity = 8192;
```

### Materialized view: Per-minute tool stats

```sql
CREATE MATERIALIZED VIEW kyb.claude_hook_events_mv
ENGINE = AggregatingMergeTree
ORDER BY (toStartOfMinute(timestamp), event_type, tool_name)
AS SELECT
    toStartOfMinute(timestamp) as minute,
    event_type,
    tool_name,
    count() as events,
    avg(duration_ms) as avg_duration_ms,
    quantile(0.95)(duration_ms) as p95_duration_ms,
    countIf(error_message != '') as error_count,
    uniq(session_id) as active_sessions
FROM kyb.claude_hook_events
GROUP BY minute, event_type, tool_name;
```

### Materialized view: Session summary

```sql
CREATE MATERIALIZED VIEW kyb.claude_session_summary_mv
ENGINE = AggregatingMergeTree
ORDER BY (toDate(timestamp), project, session_id)
AS SELECT
    session_id,
    any(project) as project,
    any(agent_id) as agent_id,
    min(timestamp) as started_at,
    max(timestamp) as last_event_at,
    dateDiff('second', min(timestamp), max(timestamp)) as duration_seconds,
    countIf(event_type = 'PostToolUse') as tool_calls,
    countIf(event_type = 'PostToolUseFailure') as tool_errors,
    countIf(tool_name = 'Bash') as bash_calls,
    countIf(tool_name = 'Edit') as edit_calls,
    countIf(tool_name = 'Write') as write_calls,
    countIf(tool_name = 'Read') as read_calls
FROM kyb.claude_hook_events
GROUP BY session_id;
```

### Migration Strategy: Separate table, not replacement

The existing `kyb.agent_events` table holds high-level agent decisions (sent via `kyb event` CLI and `kyb/reporter.rb`). The new `kyb.claude_hook_events` table captures low-level hooks data (every tool call, every session event). They coexist -- different granularity, different use cases.

> **Do NOT merge into agent_events.** The volume and schema are fundamentally different.

---

## 3. Hook Script Templates

### 3.1 Universal JSON emitter

```bash
#!/bin/bash
# /home/dev/.claude/hooks/emit-ck.sh
# Claude Code hook: emit event JSON to ClickHouse
# Fail-open: never crash Claude, never block on CK
#
# Reads JSON event from stdin, forwards to CK via HTTP.

set -o pipefail

CK_HOST="${CK_HOST:-host.orb.internal}"
CK_PORT="${CK_PORT:-8123}"
CK_DB="${CK_DB:-kyb}"
CK_TABLE="${CK_TABLE:-claude_hook_events}"
CK_URL="http://${CK_HOST}:${CK_PORT}/?query=INSERT+INTO+${CK_DB}.${CK_TABLE}+FORMAT+JSONEachRow"

# Read stdin
INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

# Enrich: add hostname and timestamp if missing
ENRICHED=$(echo "$INPUT" | python3 -c "
import json, sys, socket, os
try:
    d = json.load(sys.stdin)
except:
    sys.exit(0)
if 'timestamp' not in d or not d.get('timestamp'):
    from datetime import datetime, timezone
    d['timestamp'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
d['hostname'] = socket.gethostname()
d['pid'] = os.getpid()
d['via_proxy'] = os.environ.get('ALL_PROXY', '') != ''
print(json.dumps(d, default=str))
" 2>/dev/null)

[ -z "$ENRICHED" ] && exit 0

# Send to CK with short timeout
curl -s -X POST "$CK_URL" \
  --noproxy '*' \
  --max-time 3 \
  --connect-timeout 2 \
  -H "Content-Type: application/json" \
  -d "$ENRICHED" \
  > /dev/null 2>&1 || true

exit 0
```

### 3.2 Batched emitter (production)

For busy sessions, batching reduces CK write pressure:

```bash
#!/bin/bash
# /home/dev/.claude/hooks/emit-ck-batch.sh
# Batched emitter: queues events, flushes periodically.
# Use with a cron-flush or timer-based approach.

set -o pipefail

CK_HOST="${CK_HOST:-host.orb.internal}"
CK_PORT="${CK_PORT:-8123}"
CK_DB="${CK_DB:-kyb}"
CK_TABLE="${CK_TABLE:-claude_hook_events}"
CK_URL="http://${CK_HOST}:${CK_PORT}/?query=INSERT+INTO+${CK_DB}.${CK_TABLE}+FORMAT+JSONEachRow"

QUEUE_DIR="${CLAUDE_PROJECT_DIR:-/tmp}/.ck-hooks-queue"
mkdir -p "$QUEUE_DIR"

# Stamp event
INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

ENRICHED=$(echo "$INPUT" | python3 -c "
import json, sys, socket, os
try:
    d = json.load(sys.stdin)
except:
    sys.exit(0)
if 'timestamp' not in d or not d.get('timestamp'):
    from datetime import datetime, timezone
    d['timestamp'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
d['hostname'] = socket.gethostname()
d['pid'] = os.getpid()
d['via_proxy'] = os.environ.get('ALL_PROXY', '') != ''
print(json.dumps(d, default=str))
" 2>/dev/null)

[ -z "$ENRICHED" ] && exit 0

# Write to queue
FLUSH_COUNT=20
QUEUE_FILE="${QUEUE_DIR}/queue.jsonl"
echo "$ENRICHED" >> "$QUEUE_FILE"

# Flush if threshold reached
LINES=$(wc -l < "$QUEUE_FILE" 2>/dev/null || echo 0)
if [ "$LINES" -ge "$FLUSH_COUNT" ]; then
    DATA=$(cat "$QUEUE_FILE")
    : > "$QUEUE_FILE"
    curl -s -X POST "$CK_URL" \
      --noproxy '*' \
      --max-time 5 \
      --connect-timeout 2 \
      -H "Content-Type: application/json" \
      -d "$DATA" \
      > /dev/null 2>&1 || {
        # Re-queue on failure
        echo "$DATA" >> "$QUEUE_FILE"
    }
fi

exit 0
```

### 3.3 Standalone flush command

```bash
#!/bin/bash
# /home/dev/.claude/hooks/flush-queue.sh
# Manually flush the batch queue. Can be cron'd.
# Usage: ./flush-queue.sh

CK_HOST="${CK_HOST:-host.orb.internal}"
CK_PORT="${CK_PORT:-8123}"
CK_DB="${CK_DB:-kyb}"
CK_TABLE="${CK_TABLE:-claude_hook_events}"
CK_URL="http://${CK_HOST}:${CK_PORT}/?query=INSERT+INTO+${CK_DB}.${CK_TABLE}+FORMAT+JSONEachRow"

QUEUE_DIR="${CLAUDE_PROJECT_DIR:-/tmp}/.ck-hooks-queue"
QUEUE_FILE="${QUEUE_DIR}/queue.jsonl"

if [ -f "$QUEUE_FILE" ] && [ -s "$QUEUE_FILE" ]; then
    DATA=$(cat "$QUEUE_FILE")
    : > "$QUEUE_FILE"
    curl -s -X POST "$CK_URL" \
      --noproxy '*' \
      --max-time 5 \
      --connect-timeout 2 \
      -H "Content-Type: application/json" \
      -d "$DATA" \
      > /dev/null 2>&1 || {
        echo "$DATA" > "$QUEUE_FILE"
        echo "Flush failed, re-queued $(wc -l <<< "$DATA") events"
        exit 1
    }
fi
```

### 3.4 Periodic flush via cron

```bash
# Flush every 5 minutes
*/5 * * * * /home/dev/.claude/hooks/flush-queue.sh
```

### 3.5 Recommended: Use unbuffered emitter first

Start with the unbuffered emitter (section 3.1) for simplicity and zero data loss.
Switch to batched (3.2) only if CK write throughput becomes a concern.
At the expected volume (hundreds to low thousands of events per session), unbuffered is fine.

---

## 4. settings.json Configuration

### 4.1 Minimal config (capture everything)

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/home/dev/.claude/hooks/emit-ck.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/home/dev/.claude/hooks/emit-ck.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/home/dev/.claude/hooks/emit-ck.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/home/dev/.claude/hooks/emit-ck.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/home/dev/.claude/hooks/emit-ck.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/home/dev/.claude/hooks/emit-ck.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "SubagentStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/home/dev/.claude/hooks/emit-ck.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/home/dev/.claude/hooks/emit-ck.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

### 4.2 Where to put it

**Option A: Host settings** (all containers)
Add to `/home/dev/.claude-host-settings.json` on the host machine. The kyb container's `entrypoint.sh` already copies `.hooks` from this file into the container's `~/.claude/settings.json` on first run.

```json
{
  "hooks": { ... }
}
```

**Option B: Project-level** (per project)
Add to `<project>/.claude/settings.json` (shared via git).

**Option C: Per-container** (dev/testing)
Add directly to `~/.claude/settings.json` inside the container.

Recommendation: **Option A** (host level) for infra-wide observability. All agents in all projects get captured automatically.

### 4.3 Pre-existing settings passthrough

In `entrypoint.sh`, the settings merge already supports hooks:

```bash
jq '{
  env: .env,
  permissions: {allow: ["*"]},
  theme: "dark",
  skipDangerousModePermissionPrompt: true,
  hooks: .hooks,            # <-- already passed through
  statusLine: .statusLine,
  enabledPlugins: .enabledPlugins
}' /home/dev/.claude-host-settings.json > /home/dev/.claude/settings.json
```

---

## 5. Proxy Configuration

Current proxy state:

```bash
ALL_PROXY=socks5://kyb-infra-sing-box:2080
NO_PROXY=                   # EMPTY -- this is a bug
```

ClickHouse runs on the host network (`host.orb.internal`). SOCKS5 proxy will try (and fail) to route CK traffic. **Fix:**

### Add NO_PROXY in entrypoint.sh

```bash
export NO_PROXY="host.orb.internal,kyb-infra-*,localhost,127.0.0.1"
```

In `/home/dev/projects/kyb/entrypoint.sh`, add after the ALL_PROXY export:

```bash
# Ensure ClickHouse and infra traffic bypasses the SOCKS5 proxy
export NO_PROXY="host.orb.internal,kyb-infra-*,localhost,127.0.0.1"
```

### Hook script also uses --noproxy

The hook templates in section 3 already include `--noproxy '*'` to bypass the proxy
for the CK HTTP POST. This is the safety net in case NO_PROXY isn't set.

---

## 6. Testing Hooks

### 6.1 Test the hook script directly

```bash
# Simulate a PostToolUse event
echo '{"event":"PostToolUse","sessionId":"test-001","toolName":"Bash","input":{"command":"git status"},"output":{"exitCode":0},"durationMs":150}' \
  | /home/dev/.claude/hooks/emit-ck.sh

# Verify it landed
clickhouse-client --host host.orb.internal \
  --query "SELECT event_type, tool_name, session_id, duration_ms FROM kyb.claude_hook_events WHERE session_id='test-001'"
```

### 6.2 Test the full hook pipeline

```bash
# Add a minimal hook to settings.json temporarily
claude --settings '{
  "hooks": {
    "PostToolUse": [{"matcher":"Bash","hooks":[{"type":"command","command":"/home/dev/.claude/hooks/emit-ck.sh","timeout":5}]}]
  }
}' -p 'run: echo "hook test"'
```

### 6.3 Validate schema compliance

```bash
# Check for any parse errors
clickhouse-client --host host.orb.internal \
  --query "SELECT count(), countIf(error_message != '') as errors FROM kyb.claude_hook_events WHERE session_id='test-001'"
```

### 6.4 Debug with included hook events

```bash
# See hook events in output stream
claude --include-hook-events --output-format=stream-json -p 'echo hi' | grep -i hook
```

### 6.5 Test fail-open behavior

```bash
# Kill CK and verify Claude still works
# (simulate CK down)
sudo systemctl stop clickhouse  # or equivalent
claude -p 'echo "claude should still work even with CK down"'
sudo systemctl start clickhouse

# Verify the queue file has the events
cat /tmp/.ck-hooks-queue/queue.jsonl
```

---

## 7. Grafana Queries

### 7.1 Real-time activity dashboard

```sql
-- Active sessions now (last 5 min)
SELECT
    session_id,
    agent_id,
    project,
    count() as events,
    max(timestamp) as last_event
FROM kyb.claude_hook_events
WHERE timestamp > now() - INTERVAL 5 MINUTE
GROUP BY session_id, agent_id, project
ORDER BY last_event DESC;
```

### 7.2 Tool usage breakdown

```sql
-- Tool call distribution
SELECT
    tool_name,
    count() as calls,
    round(avg(duration_ms)) as avg_ms,
    round(quantile(0.95)(duration_ms)) as p95_ms,
    countIf(error_message != '') as errors,
    round(error_count / count() * 100, 1) as error_rate_pct
FROM kyb.claude_hook_events
WHERE event_type = 'PostToolUse'
  AND timestamp > now() - INTERVAL 1 HOUR
GROUP BY tool_name
ORDER BY calls DESC;
```

### 7.3 Session timeline

```sql
-- Events per session, chronological
SELECT
    timestamp,
    event_type,
    tool_name,
    duration_ms,
    substring(tool_input, 1, 100) as input_preview,
    error_message
FROM kyb.claude_hook_events
WHERE session_id = 'faab8111-...'
  AND project = 'kyb'
ORDER BY timestamp;
```

### 7.4 Long-running tools

```sql
-- Slowest tool calls
SELECT
    timestamp,
    session_id,
    tool_name,
    duration_ms,
    substring(tool_input, 1, 200) as input_preview
FROM kyb.claude_hook_events
WHERE event_type = 'PostToolUse'
  AND duration_ms > 30000  -- >30s
  AND timestamp > now() - INTERVAL 1 DAY
ORDER BY duration_ms DESC;
```

### 7.5 Error rate over time

```sql
SELECT
    toStartOfHour(timestamp) as hour,
    tool_name,
    count() as total,
    countIf(error_message != '') as errors
FROM kyb.claude_hook_events
WHERE timestamp > now() - INTERVAL 24 HOUR
GROUP BY hour, tool_name
ORDER BY hour;
```

### 7.6 Subagent activity

```sql
-- Subagent forks and results
SELECT
    timestamp,
    session_id as parent_session,
    subagent_task,
    error_message
FROM kyb.claude_hook_events
WHERE event_type IN ('SubagentStart', 'SubagentStop')
  AND timestamp > now() - INTERVAL 1 DAY
ORDER BY timestamp;
```

### 7.7 Per-project activity

```sql
SELECT
    project,
    uniq(session_id) as sessions,
    count() as events,
    countIf(event_type = 'PostToolUseFailure') as failures,
    sum(duration_ms) / 1000 as total_tool_seconds
FROM kyb.claude_hook_events
WHERE timestamp > now() - INTERVAL 1 DAY
GROUP BY project
ORDER BY events DESC;
```

### 7.8 Hooks health check

```sql
-- Monitors: is the hooks pipeline working?
SELECT
    toStartOfMinute(timestamp) as minute,
    count() as events_per_minute,
    countIf(session_id = 'test-001') as test_events
FROM kyb.claude_hook_events
WHERE timestamp > now() - INTERVAL 10 MINUTE
GROUP BY minute
ORDER BY minute;
```

---

## 8. Volume Estimation

### Current baseline

| Metric | Value |
|--------|-------|
| Total agent_events (all time) | 47 rows |
| Events today (2026-05-22) | 34 rows |
| Sessions today | ~5-6 |
| Peak hourly rate | ~20 events |
| Band per session | ~5-10 events |

Agent events are high-level decisions, not tool calls. With hooks we capture **every** tool call.

### Projected with hooks

| Metric | Low | Medium | Busy |
|--------|-----|--------|------|
| Tool calls per session | 50 | 200 | 1000 |
| Sessions per day | 5 | 20 | 50 |
| Events per day | 250 | 4,000 | 50,000 |
| Events per second | 0.003 | 0.05 | 0.6 |
| Storage per day | 0.5 MB | 8 MB | 100 MB |
| Storage per month (30d TTL) | 15 MB | 240 MB | 3 GB |

### Takeaway

At the current usage level (medium), hooks generate ~4K events/day = ~240 MB/month.
This is negligible for ClickHouse. Even at "busy" (50 sessions, 1K tool calls each), 3 GB/month is well within a single-node CK's capacity.

TTL of 30 days keeps storage bounded.

---

## 9. Error Handling & Fail-Open

### Principles

1. **NEVER crash Claude.** A hook script that fails must not propagate its failure.
2. **NEVER block the tool.** PreToolUse hooks should always exit 0 unless you intentionally want to block.
3. **CK availability is optional.** Claude must work perfectly when CK is down.

### Implementation in hook scripts

```bash
# Fail-open pattern
{
    # ... hook logic ...
} 2>/dev/null || true  # Swallow ALL errors

# NEVER:
set -e  # DANGER: will crash Claude
```

### What happens when

| Scenario | Hook behavior | Claude behavior |
|----------|--------------|-----------------|
| CK is down | curl fails silently | Unaffected |
| Hook script crashes (syntax error) | Bash exits non-zero | Claude log shows warning, continues |
| Hook timeout (5s) | Claude kills the hook process | PreToolUse: tool is blocked (bad!) |
| Hook returns non-zero (PreToolUse) | Claude blocks the tool | Tool execution cancelled |
| Network misconfigured | curl fails silently | Unaffected |
| Disk full (can't write queue) | Write fails silently | Unaffected |
| Invalid JSON from Claude | Python parse error, exit 0 | Unaffected |

### Critical: PreToolUse timeout

If a PreToolUse hook times out (default 60s), Claude **blocks the tool**.
Set `"timeout": 5` on ALL PreToolUse hooks to minimize the damage window:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/home/dev/.claude/hooks/emit-ck.sh",
            "timeout": 5        # <-- MUST be short
          }
        ]
      }
    ]
  }
}
```

PostToolUse and other non-blocking hooks are safe regardless.

### Monitoring hook health

```sql
-- Alert if no events received in 15 minutes
SELECT count() as recent_events
FROM kyb.claude_hook_events
WHERE timestamp > now() - INTERVAL 15 MINUTE;
```

---

## 10. Comparison with kyb.reporter

### Current system: `kyb/reporter.rb` + `kyb agent_events`

```ruby
# kyb/reporter.rb
CLICKHOUSE_HOST = 'host.orb.internal'
CLICKHOUSE_PORT = 8123

def emit(event_type, data = {})
  http_post("/?query=INSERT INTO #{CLICKHOUSE_DB}.#{METRICS_TABLE} FORMAT JSONEachRow",
            JSON.generate(row))
end
```

| Aspect | kyb.reporter | Claude Hooks |
|--------|-------------|--------------|
| **Trigger** | CLI commands (`kyb create`, `kyb rm`, `kyb event dispatch`) | Every tool call in Claude Code |
| **Data** | High-level agent decisions (`decision`, `finding`, `fix`, `done`) | Low-level tool execution (Bash, Edit, Write, Read) |
| **Volume** | ~5-50 events/day | ~250-50,000 events/day |
| **Latency** | Real-time (HTTP POST) | Near-real-time (batch or per-event) |
| **Reliability** | Ruby HTTP error handling | Shell script fail-open |
| **Schema** | Flat row with event_type + data JSON | Structured columns per tool type |
| **Granularity** | Per-agent-decision | Per-tool-call |
| **Session tracking** | Manual (session_start/session_complete) | Automatic (SessionStart/SessionEnd) |
| **Agent tracking** | Manual (agent_id in content) | Automatic (agent_id, subagent chain) |
| **Error capture** | Manual (fix, root_cause events) | Automatic (PostToolUseFailure, exit codes) |
| **Dependencies** | Ruby + Net::HTTP | Bash + curl |
| **Code location** | `/home/dev/projects/kyb/lib/kyb/reporter.rb` | `/home/dev/.claude/hooks/emit-ck.sh` |

### Decision: Coexist

**Do NOT migrate.** They serve different purposes:

- **kyb.reporter** captures **semantic intent** -- the "why": decisions, findings, dispatch commands. This is irreplaceable because it records the boss agent's reasoning, not just raw tool calls.
- **Claude hooks** capture **mechanistic execution** -- the "what": every Bash command run, every file written, duration, errors. This fills the gap that currently has zero visibility.

### Future integration

Possible bridge: have the hook script also call `kyb event` for high-level events
(e.g., on `SubagentStart`, emit `kyb event dispatch`). But for now, keep them separate.

```
┌──────────────────────────────────────────┐
│          Claude Code Session             │
│                                          │
│  ┌─────────────────────┐  ┌───────────┐ │
│  │   Claude Hooks      │  │ kyb CLI   │ │
│  │   (every tool call) │  │ (agent    │ │
│  │   ──────────→ CK   │  │  events)  │ │
│  │   claude_hook_events│  │ ───→ CK  │ │
│  └─────────────────────┘  │ agent_   │ │
│                           │ events   │ │
│                           └───────────┘ │
└──────────────────────────────────────────┘
```

---

## Appendix: Implementation Checklist

- [ ] Create `kyb.claude_hook_events` table in ClickHouse
- [ ] Create materialized views for per-minute stats and session summary
- [ ] Write `/home/dev/.claude/hooks/emit-ck.sh` (unbuffered emitter)
- [ ] Make it executable: `chmod +x /home/dev/.claude/hooks/emit-ck.sh`
- [ ] Add `hooks` block to `/home/dev/.claude-host-settings.json`
- [ ] Set `timeout: 5` for PreToolUse hooks
- [ ] Add `NO_PROXY` to entrypoint.sh (host.orb.internal, kyb-infra-*)
- [ ] Test: inject a test event, verify in CK
- [ ] Test: CK down, verify Claude works normally
- [ ] Test: monte carlo -- 100 rapid tool calls, verify no data loss
- [ ] Add Grafana dashboard (panels from section 7)
- [ ] Add hooks health check alert (if no events in 15 min)
- [ ] Monitor for first week: verify volume projections, tune timeout/batching

---

## Appendix: Debugging Hooks with --debug

```bash
# Enable hook-specific debug output
claude --debug hooks -p 'echo hi'

# Categories:
#   hooks       - Hook lifecycle (install, resolve, run, result)
#   hook:config - Hook configuration loading
#   hook:run    - Hook execution details

# All debug categories
claude --debug all -p 'echo hi'
```

---

> Written for kyb infra-observability initiative. Claude Code 2.1.148, ClickHouse 25.1.
