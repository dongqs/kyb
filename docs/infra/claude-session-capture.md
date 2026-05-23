# Claude Code Session Capture for ClickHouse

Capture **every message, every tool call, every subagent** from Claude Code into
ClickHouse for observability, debugging, and collective memory.

---

## 1. Current State

### 1.1 What Claude Stores Locally

| Path | Format | Contents | Size (this session) |
|---|---|---|---|
| `~/.claude/sessions/<pid>.json` | JSON | Active session metadata (pid, sessionId, status) | ~250 B |
| `~/.claude/history.jsonl` | JSONL | Lightweight index of all conversations (display text only) | 12 KB |
| `~/.claude/projects/<project>/<sessionId>.jsonl` | JSONL | **Root agent** full conversation: messages, tool calls, attachments (1363 events) | 2.2 MB |
| `~/.claude/projects/<project>/<sessionId>/subagents/agent-<id>.jsonl` | JSONL | **Subagent** full conversation (42 agents, 4209 events total) | 8.2 MB |
| `~/.claude/projects/<project>/<sessionId>/subagents/agent-<id>.meta.json` | JSON | Subagent metadata: type, description, toolUseId, worktreePath | ~200 B each |
| `~/.claude/.claude.json` | JSON | Project trust config | ~1.9 KB |
| `~/.claude/backups/` | JSON | Rollback backups of `.claude.json` | 5 files, ~20 KB |

**Root session event types** (from a single 8-hour session):

| Type | Count | Description |
|---|---|---|
| `assistant` | 591 | AI responses (thinking + tool_use + text blocks) |
| `user` | 289 | User messages |
| `queue-operation` | 120 | Subagent lifecycle (enqueue/dequeue/remove) |
| `attachment` | 56 | File attachments |
| `permission-mode` | 55 | Permission prompts/bypasses |
| `system` | 63 | System events (turn_duration, etc.) |
| `file-history-snapshot` | 39 | File state snapshots |
| `last-prompt` | 54 | Last prompt per conversation branch |
| `ai-title` | 54 | Conversation titles |
| `pr-link` | 42 | PR links |

**Subagent event types** (aggregated across 42 agents):

| Type | Count |
|---|---|
| `assistant` | 2626 |
| `user` | 1541 |

### 1.2 Existing ClickHouse Infrastructure

**`kyb.agent_events` table:**

```sql
CREATE TABLE kyb.agent_events (
    timestamp DateTime,
    agent_id String,
    session_id String,
    task_id String,
    project String,
    event_type String,
    content String,
    parent_agent_id String,
    tags Map(String, String)
) ENGINE = MergeTree
ORDER BY (project, timestamp)
```

- 47 rows total (manual entries from boss agent)
- `parent_agent_id` field exists but never populated
- Populated via manual shell calls (not automated)

**`kyb.reporter` Ruby module** (`lib/kyb/reporter.rb`):
- HTTP POST to `host.orb.internal:8123`
- Generic `emit(event_type, data)` method
- 3s timeout, JSONEachRow format
- Automatic events: session_start, session_complete, container_create, container_rm, etc.
- Sends to `kyb.metrics` and `kyb.sessions` tables (neither exists yet)

### 1.3 How Subagents Work

1. Root agent calls `Agent` tool with `{description, prompt, isolation?, run_in_background}`
2. Claude spawns a **separate process** with its own workspaces, sessions, and hooks
3. Subagent gets its own JSONL file in `subagents/agent-<id>.jsonl`
4. Meta file links subagent to the original tool call: `toolUseId` matches the `Agent` tool call `id`
5. Root session records `queue-operation {enqueue, dequeue, remove}` events
6. Some subagents get isolated worktrees (`worktreePath` in meta.json)
7. **Each subagent is its own Claude process** -- hooks in the parent cannot directly see subagent internals

### 1.4 Volume Estimates

| Metric | Single Session | Per Day (5 sessions) | Per Month |
|---|---|---|---|
| Events (root) | ~1,400 | ~7,000 | ~210,000 |
| Events (subagents) | ~4,200 | ~21,000 | ~630,000 |
| **Total events** | **~5,600** | **~28,000** | **~840,000** |
| Raw disk | ~10.4 MB | ~52 MB | ~1.5 GB |
| CK compressed (est. 4x) | ~2.6 MB | ~13 MB | ~380 MB |

CK handles this volume trivially. Even at 10x the rate, storage is negligible.

---

## 2. Approaches to Capture

### 2.1 Approach A: Claude Code Hooks (settings.json) -- RECOMMENDED (Phase 1)

**What's possible:**
Claude Code supports hooks in `settings.json`:

```json
{
  "hooks": {
    "BeforeCommand": "script",
    "AfterCommand": "script",
    "BeforeRead": "script",
    "AfterRead": "script",
    "BeforeEdit": "script",
    "AfterEdit": "script",
    "BeforeTool": "script",
    "AfterTool": "script",
    "BeforeNotification": "script",
    "AfterNotification": "script"
  }
}
```

Each hook receives context via env vars (tool name, input, result, duration, etc.).

**Pros:**
- Real-time capture
- Low overhead (script runs, process exits)
- No modification to Claude Code internals
- Captures all standard tools (Bash, Read, Edit, Write, WebSearch, etc.)

**Cons:**
- **Each subagent is a separate process** with its own hook context
- Hooks run once per event, cannot correlate between hooks
- Limited to what Claude exposes via env vars
- Hook scripts need to be fast (blocking)

**Subagent workaround:**
- Pass `CLAUDE_PARENT_SESSION_ID` env var to subagent processes
- Subagent hooks read this env var to know their parent
- Each subagent writes to CK with its own `session_id` + `parent_session_id`

**How to propagate:**
Claude Code likely spawns subagents via `node` child_process. The host `settings.json` hooks apply to ALL Claude processes on the machine -- including subagents. So if hooks are configured at the host level, they fire for both root and subagent.

### 2.2 Approach B: Wrapping the `claude` CLI

**What:**
Replace `/usr/local/bin/claude` with a wrapper script that:
1. Records `session_start` with env vars (project, branch, model)
2. Calls real `claude` binary
3. Records `session_complete` with duration and exit code
4. Strips sensitive env vars before passing through

**Pros:**
- Catches every Claude invocation
- Simple to implement
- Can inject hooks config on the fly

**Cons:**
- Only captures lifecycle, not tool calls
- Doesn't see inside the session
- Must coexist with Claude's own binary discovery

### 2.3 Approach C: Parse JSONL Files Post-Hoc

**What:**
A cron job or on-demand script that:
1. Scans `~/.claude/projects/*/<sessionId>.jsonl`
2. Parses each event, extracts structured data
3. Batches inserts into CK

**Pros:**
- **Completeness**: captures everything Claude stores
- No runtime overhead
- Can backfill historical data
- Can reconstruct full conversation trees

**Cons:**
- **Not real-time**: data only lands after session ends or on a schedule
- **Race conditions**: reading JSONL while Claude is writing
- More complex parsing (Claude's JSONL has embedded Python-repr dicts that need `ast.literal_eval`)
- Need to handle partial sessions (in-progress)

**Data extraction per event type:**

| Type | CK Table | Extraction |
|---|---|---|
| `user` | `tool_calls` | message text, timestamp, parentUuid |
| `assistant` | `tool_calls` | emit one row per content block (tool_use, text, thinking) |
| `system.turn_duration` | `sessions` | durationMs, messageCount |
| `queue-operation` | `subagent_spawns` | operation, task-id, tool-use-id |
| `pr-link` | `tool_calls` / `sessions` | prNumber, prUrl |
| `attachment` | `tool_calls` | filename, type |

### 2.4 Approach D: kyb exec Wrapper

**What:**
All commands within a kyb container go through `kyb exec`. Wrap this to log all commands + output.

**Pros:**
- Already have reporter infrastructure
- Captures actual command execution (useful for debugging)

**Cons:**
- Doesn't capture non-command tools (Read, Edit, Write, WebSearch)
- Doesn't capture thinking/planning
- Subagents in worktrees may bypass kyb exec

### 2.5 Approach E: Docker-Level Capture

Too low-level. Hard to correlate container events to Claude sessions. Not recommended.

---

## 3. Recommended Architecture: Hybrid (Hooks + JSONL Backfill)

```
┌─────────────────────────────────────────────────────────┐
│                    Claude Code Process                    │
│  ┌─────────────────────────────────────────────────────┐ │
│  │  settings.json hooks fire for every tool call       │ │
│  │  BeforeTool → emit to CK (real-time)                │ │
│  │  AfterTool  → emit to CK (real-time, with result)   │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  spawns subagents (separate processes)                   │
│  ┌─────────────────────────────────────────────────────┐ │
│  │  Subagent reads CLAUDE_PARENT_SESSION_ID from env   │ │
│  │  Subagent hooks fire independently, emit with       │ │
│  │  their own session_id + parent_session_id            │ │
│  └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  CLI wrapper (entrypoint.sh)                            │
│  - Captures session start/stop                          │
│  - Injects hooks config                                 │
│  - Passes parent_session_id via env                     │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  JSONL Backfill (cron, every 5 min or on demand)        │
│  - Parses completed sessions for completeness           │
│  - Fills gaps hooks might have missed                   │
│  - Summarizes: token estimates, duration, tool counts   │
└─────────────────────────────────────────────────────────┘

                        ▼
            ┌─────────────────────┐
            │   ClickHouse 25.1   │
            │  host.orb.internal  │
            │  kyb.claude_* tables │
            └─────────────────────┘
```

### 3.1 Why Hybrid

| Requirement | Hooks | JSONL Backfill |
|---|---|---|
| Real-time visibility | Yes | No |
| Complete capture | No (API-level gaps) | Yes |
| Subagent capture | Yes (with env propagation) | Yes |
| Low overhead | Yes | Yes |
| Historical backfill | No | Yes |
| Simple implementation | Medium | Medium |

Combined: **hooks for real-time** + **JSONL backfill** for completeness and gap-filling.

---

## 4. Schema Design

### 4.1 `claude_sessions` -- Session lifecycle

```sql
CREATE TABLE kyb.claude_sessions (
    session_id String,
    parent_session_id String,
    root_session_id String,          -- top-most ancestor for tree traversal
    agent_type LowCardinality(String), -- 'root', 'subagent'
    project String,
    branch String,
    model String,
    claude_version String,
    start_time DateTime64(3),
    end_time DateTime64(3),
    duration_ms UInt32,
    status Enum8('active'=1, 'completed'=2, 'error'=3),
    tool_call_count UInt32,
    turn_count UInt32,
    total_thinking_chars UInt32,
    total_output_chars UInt32,
    error_message String,
    metadata Map(String, String),
    hostname String,
    pid UInt32
) ENGINE = MergeTree
ORDER BY (project, start_time, session_id)
TTL toDate(start_time) + INTERVAL 90 DAY;
```

### 4.2 `claude_tool_calls` -- Every tool invocation

```sql
CREATE TABLE kyb.claude_tool_calls (
    timestamp DateTime64(3),
    session_id String,
    parent_session_id String,
    root_session_id String,
    agent_type LowCardinality(String),
    message_uuid String,              -- links to parent message in conversation
    parent_message_uuid String,       -- threading
    turn_number UInt32,               -- sequential turn in conversation
    tool_name LowCardinality(String), -- Bash, Read, Edit, Write, Agent, WebSearch, etc.
    tool_id String,                   -- call_xxx identifier
    tool_input_summary String,        -- first 500 chars
    tool_result_summary String,       -- first 500 chars
    duration_ms UInt32,
    success UInt8,
    error_message String,
    model String,
    project String,
    branch String,
    thinking_chars UInt32,
    output_tokens UInt32              -- estimated
) ENGINE = MergeTree
ORDER BY (session_id, timestamp)
TTL toDate(timestamp) + INTERVAL 30 DAY;
```

### 4.3 `claude_messages` -- Full text of messages (optional, search use case)

```sql
CREATE TABLE kyb.claude_messages (
    timestamp DateTime64(3),
    session_id String,
    message_uuid String,
    parent_message_uuid String,
    role LowCardinality(String),       -- 'user', 'assistant', 'system'
    message_type LowCardinality(String), -- 'text', 'tool_use', 'tool_result', 'thinking'
    content String,                    -- full text
    token_estimate UInt32,
    model String
) ENGINE = MergeTree
ORDER BY (session_id, timestamp)
TTL toDate(timestamp) + INTERVAL 7 DAY;  -- short TTL, high volume
```

### 4.4 `claude_subagent_spawns` -- Subagent lifecycle

```sql
CREATE TABLE kyb.claude_subagent_spawns (
    timestamp DateTime64(3),
    parent_session_id String,
    subagent_session_id String,        -- matches the subagent's claude_sessions.session_id
    subagent_id String,                -- agent-xxx (derived from meta.json)
    description String,
    tool_use_id String,                -- matches Agent tool call id
    worktree_path String,
    agent_type String,
    status Enum8('spawned'=1, 'running'=2, 'completed'=3, 'failed'=4),
    duration_ms UInt32,
    output_tokens UInt32
) ENGINE = MergeTree
ORDER BY (parent_session_id, timestamp)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

### 4.5 `claude_session_views` -- Materialized view for daily summaries

```sql
CREATE MATERIALIZED VIEW kyb.claude_session_views
ENGINE = AggregatingMergeTree
ORDER BY (project, toDate(start_time))
AS SELECT
    project,
    toDate(start_time) AS day,
    countState() AS session_count,
    sumState(tool_call_count) AS total_tool_calls,
    avgState(duration_ms) AS avg_duration_ms,
    countStateIf(status = 'error') AS error_count,
    uniqState(session_id) AS unique_agents
FROM kyb.claude_sessions
GROUP BY project, day;
```

### 4.6 `claude_event_log` -- Unified event stream (lightweight alternative)

If separate tables are too much, a single unified event log:

```sql
CREATE TABLE kyb.claude_event_log (
    timestamp DateTime64(3),
    session_id String,
    parent_session_id String,
    root_session_id String,
    event_type LowCardinality(String), -- 'session_start', 'session_end', 'tool_call',
                                       -- 'tool_result', 'subagent_spawn', 'subagent_complete',
                                       -- 'user_message', 'thinking', 'turn_duration', 'pr_link'
    event_name String,                  -- tool name or sub-event name
    agent_type LowCardinality(String),
    project String,
    branch String,
    duration_ms UInt32,
    status LowCardinality(String),      -- 'success', 'error', 'in_progress'
    summary String,                      -- first 500 chars of context
    metadata Map(String, String)
) ENGINE = MergeTree
ORDER BY (session_id, timestamp)
TTL toDate(timestamp) + INTERVAL 30 DAY;
```

This is simpler to query and closer to the existing `agent_events` pattern.

---

## 5. Subagent Tracking

### 5.1 The Problem

Each subagent is a **separate OS process**. Hooks in the root agent's `settings.json` won't fire for subagent tool calls. Each subagent has its own JSONL, its own session, its own hook context.

### 5.2 Solution: Env Var Propagation

**Step 1: Inject hooks at the system level**

In `entrypoint.sh`, add hooks directly to `~/.claude-host-settings.json` (not per-project settings.json, since subagents may not be in a project directory):

```json
{
  "hooks": {
    "AfterTool": "/usr/local/bin/claude-hook-aftertool"
  },
  "env": {
    "CLAUDE_PARENT_SESSION_ID": ""
  }
}
```

These hooks apply to **every** Claude Code process on the system -- root AND subagents.

**Step 2: Root agent hook records its session_id**

`/usr/local/bin/claude-hook-aftertool`:
```bash
#!/bin/bash
# Called by Claude after every tool call
# Env vars from Claude: CLAUDE_TOOL_NAME, CLAUDE_TOOL_INPUT, etc.
# Our env var: CLAUDE_PARENT_SESSION_ID (empty for root)

SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
PARENT_ID="${CLAUDE_PARENT_SESSION_ID:-}"

# Build parent chain
if [ -z "$PARENT_ID" ]; then
  ROOT_ID="$SESSION_ID"
else
  # Inherit root ID from parent
  ROOT_ID="${CLAUDE_ROOT_SESSION_ID:-$PARENT_ID}"
fi

# Emit to CK
curl -s -X POST "http://host.orb.internal:8123/?query=INSERT%20INTO%20kyb.claude_event_log%20FORMAT%20JSONEachRow" \
  -d "$(jo timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) \
           session_id="$SESSION_ID" \
           parent_session_id="$PARENT_ID" \
           root_session_id="$ROOT_ID" \
           event_type=tool_call \
           event_name="$CLAUDE_TOOL_NAME" \
           project="${KYB_PROJECT:-}" \
           duration_ms="${CLAUDE_TOOL_DURATION_MS:-0}" \
           status=success \
           summary="${CLAUDE_TOOL_INPUT:0:500}")" &
```

**Step 3: Subagent inherits parent chain**

When Claude spawns a subagent, it inherits env vars from the parent process. So `CLAUDE_PARENT_SESSION_ID` and `CLAUDE_ROOT_SESSION_ID` are automatically propagated.

The subagent itself also has a `CLAUDE_SESSION_ID` (set by its own Claude process). Its hooks will see:
- `CLAUDE_SESSION_ID` = subagent's own session
- `CLAUDE_PARENT_SESSION_ID` = root agent's session
- `CLAUDE_ROOT_SESSION_ID` = root agent's session (same for all levels)

### 5.3 What About Worktrees?

Subagents with `worktreePath` get their own directory. The env vars on the subagent process remain intact because `EnterWorktree` doesn't clear env vars -- it `cd`s into the worktree directory. The hooks in `~/.claude-host-settings.json` still apply.

### 5.4 Limitation: Hook Env Vars

The exact env var names Claude Code exposes to hooks need verification. Based on Claude's hook documentation:

| Env Var | Expected | Available at |
|---|---|---|
| `CLAUDE_TOOL_NAME` | Name of tool being called | BeforeTool, AfterTool |
| `CLAUDE_TOOL_INPUT` | JSON of tool input | BeforeTool |
| `CLAUDE_TOOL_RESULT` | JSON of tool output | AfterTool |
| `CLAUDE_TOOL_DURATION_MS` | Duration | AfterTool |
| `CLAUDE_ERROR` | Error message | AfterTool on failure |
| `CLAUDE_FILE_PATH` | File being read/edited | BeforeRead, BeforeEdit, etc. |
| `CLAUDE_SESSION_ID` | Current session | All hooks |

If `CLAUDE_SESSION_ID` is not exposed, we can extract it from the JSONL filenames or from `~/.claude/sessions/<pid>.json`.

---

## 6. Integration with kyb.reporter

### 6.1 Current reporter

```ruby
module Kyb::Reporter
  CLICKHOUSE_HOST = ENV.fetch('CLICKHOUSE_HOST', 'host.orb.internal')
  CLICKHOUSE_PORT = 8123

  def emit(event_type, data = {})
    # Generic event emitter
    row = { timestamp: Time.now.utc, event: event_type, hostname:, pid:, data: }
    http_post("/?query=INSERT INTO kyb.metrics FORMAT JSONEachRow", JSON.generate(row))
  end
end
```

### 6.2 New claude_capture module

```ruby
module Kyb::ClaudeCapture
  module_function

  CK_HOST = ENV.fetch('CLICKHOUSE_HOST', 'host.orb.internal')
  CK_PORT = 8123

  # Called by hooks (via HTTP or pipe)
  def record_tool_call(session_id:, parent_session_id:, tool_name:,
                       tool_input:, duration_ms:, success:, error: nil)
    row = {
      timestamp: Time.now.utc.iso8601(3),
      session_id: session_id,
      parent_session_id: parent_session_id || '',
      root_session_id: parent_session_id || session_id,
      tool_name: tool_name,
      tool_input_summary: tool_input.to_s[0..500],
      duration_ms: duration_ms,
      success: success ? 1 : 0,
      error_message: error.to_s
    }
    http_post("INSERT INTO kyb.claude_event_log FORMAT JSONEachRow", row)
  end

  # Bulk backfill from JSONL files
  def backfill_session(session_id)
    # Parse .../projects/*/<sessionId>.jsonl
    # Parse .../subagents/agent-*.jsonl
    # Insert sessions, tool_calls, subagent_spawns into CK
  end
end
```

### 6.3 Hook script calling kyb

The hook script can invoke `kyb capture record --session-id "$CLAUDE_SESSION_ID" ...` to leverage the Ruby module. This is cleaner than calling CK from bash.

---

## 7. Implementation Phases

### Phase 1: Real-time Hook Capture (root agent only) -- 1-2 days

1. **Add hooks to settings.json generation** in `entrypoint.sh`
   - Write `/usr/local/bin/claude-hook-aftertool` bash script
   - Hardcoded: emit tool calls to CK via curl
   - Include in `~/.claude-host-settings.json`

2. **Create CK tables** via migration script
   - Start with `claude_event_log` table (simplest, closest to existing pattern)
   - Or use existing `agent_events` table with new event types

3. **Verify capture works**:
   - Run Claude, make a few tool calls
   - Query CK: `SELECT * FROM kyb.claude_event_log`
   - Verify all tool calls, durations, success/failure are captured

4. **Estimated volume**: ~100-200 tool calls per active hour, negligible CK load

**Deliverables:**
- [ ] Hook script installed at `/usr/local/bin/claude-hook-aftertool`
- [ ] `entrypoint.sh` updated to include hooks in settings.json
- [ ] CK tables created
- [ ] Verified: tool calls from root agent appear in CK in real-time

### Phase 2: Subagent Chaining -- 1-2 days

1. **Identify subagent env propagation**:
   - Test: does `CLAUDE_PARENT_SESSION_ID` survive into subagent processes?
   - If not, find how Claude spawns subagents and inject env vars

2. **Update hook script** to read `CLAUDE_PARENT_SESSION_ID` and `CLAUDE_ROOT_SESSION_ID`

3. **Verify**:
   - Spawn subagents
   - Query CK: `SELECT parent_session_id, count() FROM kyb.claude_event_log GROUP BY parent_session_id`
   - Confirm subagent events are linked to parent

**Potential issues:**
- Subagent spawned in worktree may not have hooks if worktree has its own `settings.json`
- Solution: ensure `~/.claude-host-settings.json` sets `hooks` -- this overrides per-project settings

**Deliverables:**
- [ ] Subagent tool calls appear in CK with parent_session_id set
- [ ] Can reconstruct session trees: `SELECT * FROM claude_event_log WHERE root_session_id = 'xxx'`

### Phase 3: Session Lifecycle Capture -- 2-3 days

1. **CLI wrapper** (`/usr/local/bin/claude-wrapper`):
   - Records `session_start` before exec
   - Records `session_end` with duration and tool count after exec

2. **Parse turn_duration events** from JSONL to get per-turn metrics

3. **Store in `claude_sessions` table**

**Deliverables:**
- [ ] Session start/stop events in CK
- [ ] `claude_sessions` table populated
- [ ] Dashboard can show active sessions, durations, tool usage

### Phase 4: JSONL Backfill -- 2-3 days

1. **Build `kyb capture backfill` command**:
   - Scans `~/.claude/projects/*/` for JSONL files
   - For each completed session (no active pid), parse all events
   - Bulk insert into CK via INSERT ... FORMAT JSONEachRow (batch of 1000)

2. **Handle embedded data formats**:
   - Claude stores message content as Python-repr dict strings
   - Need `ast.literal_eval` or regex parsing to extract fields

3. **Subagent linkage**:
   - Parse `subagents/agent-*.meta.json` for toolUseId
   - Match to `Agent` tool calls in root session
   - Insert into `claude_subagent_spawns`

4. **Set up cron job**: `*/5 * * * * kyb capture backfill --max-age=7d`

**Deliverables:**
- [ ] `kyb capture backfill` command
- [ ] All historical sessions in CK
- [ ] Cron job for ongoing backfill

### Phase 5: Dashboards and Alerts -- 1-2 days

1. **Grafana dashboard** (if Grafana is available):
   - Daily active sessions
   - Tool usage breakdown
   - Error rate per tool
   - Subagent spawn tree
   - Session duration distribution

2. **Alerts**:
   - No session activity for >30 min (Claude may be stuck)
   - High error rate in tool calls
   - Subagent timeout rate > 10%

**Deliverables:**
- [ ] Grafana dashboard URL
- [ ] Basic alert rules

---

## 8. Edge Cases and Risks

### 8.1 Concurrent Sessions
Multiple Claude sessions can run simultaneously (e.g., root + subagents). The session_id and root_session_id fields handle this. Add a `hostname` + `pid` combination for disambiguation if needed.

### 8.2 Large Output Blowups
Tool results can be megabytes (e.g., `cat` of a large file, `ls -la` of a big directory). Solution: **truncate `tool_result_summary` to 500 chars**. Store full results separately if needed (add a `content` table with 7-day TTL).

### 8.3 Hook Script Failure
If the hook script crashes (timeout, CK unavailable), Claude should NOT be blocked. Hook scripts must:
- Use `&` (background) or `timeout` wrapper
- Never return non-zero exit (Claude may interpret as hook failure)
- Set `|| true` as safety net

### 8.4 CK Down
If CK is unreachable, hooks should gracefully degrade:
- Don't error
- Optionally buffer to local file for retry
- JSONL backfill will catch any gaps

### 8.5 Subagent Without Env Propagation
If `CLAUDE_PARENT_SESSION_ID` doesn't survive into subagent processes:
- Alternative 1: Scan proc filesystem (`/proc/<pid>/environ`) to find parent
- Alternative 2: Use JSONL backfill as primary capture, hooks as supplementary
- Alternative 3: Inject via Docker/container environment

### 8.6 Worktree Isolation
Subagents in isolated worktrees have their own `~/.claude/` context. Hooks must be configured at the **host level** (`~/.claude-host-settings.json`), not in project-level `settings.json`, because worktrees may regenerate settings.json.

---

## 9. Comparison Summary

| Approach | Real-time | Subagent | Completeness | Effort | Risk |
|---|---|---|---|---|---|
| **A: Hooks** (Phase 1-2) | Yes | Yes (with env) | Medium (tool calls only) | Low | Low |
| **B: CLI Wrapper** (Phase 3) | Yes | Partial | Low (lifecycle only) | Low | Low |
| **C: JSONL Backfill** (Phase 4) | No | Yes | **Complete** | Medium | Low |
| **D: kyb exec wrapper** | Yes | No | Low | Low | Low |
| **E: Docker capture** | Yes | Yes | Very low | High | High |

**Verdict:** Phase 1-2 = **A** (hooks), Phase 3 = **B** (CLI wrapper), Phase 4 = **C** (JSONL backfill), Phase 5 = dashboards.

---

## 10. Quick Start (Phase 1 MVP)

### Step 1: Create event log table

```bash
clickhouse-client --host host.orb.internal <<'SQL'
CREATE TABLE IF NOT EXISTS kyb.claude_event_log (
    timestamp DateTime64(3),
    session_id String,
    parent_session_id String,
    root_session_id String,
    event_type LowCardinality(String),
    event_name String,
    agent_type LowCardinality(String),
    project String,
    branch String,
    duration_ms UInt32,
    status LowCardinality(String),
    summary String,
    metadata Map(String, String)
) ENGINE = MergeTree
ORDER BY (session_id, timestamp)
TTL toDate(timestamp) + INTERVAL 30 DAY;
SQL
```

### Step 2: Install hook script

```bash
cat > /usr/local/bin/claude-hook-aftertool <<'SCRIPT'
#!/bin/bash
set -euo pipefail

SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
PARENT_ID="${CLAUDE_PARENT_SESSION_ID:-}"
ROOT_ID="${CLAUDE_ROOT_SESSION_ID:-${PARENT_ID:-$SESSION_ID}}"
TOOL_NAME="${CLAUDE_TOOL_NAME:-unknown}"
DURATION="${CLAUDE_TOOL_DURATION_MS:-0}"
STATUS="success"
[ -n "${CLAUDE_ERROR:-}" ] && STATUS="error"

# Background to avoid blocking Claude
curl -s -X POST "http://host.orb.internal:8123/?query=INSERT%20INTO%20kyb.claude_event_log%20FORMAT%20JSONEachRow" \
  -d "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\",\"session_id\":\"$SESSION_ID\",\"parent_session_id\":\"$PARENT_ID\",\"root_session_id\":\"$ROOT_ID\",\"event_type\":\"tool_call\",\"event_name\":\"$TOOL_NAME\",\"duration_ms\":$DURATION,\"status\":\"$STATUS\",\"summary\":\"${CLAUDE_TOOL_INPUT:0:500}\"}" \
  >/dev/null 2>&1 || true
SCRIPT
chmod +x /usr/local/bin/claude-hook-aftertool
```

### Step 3: Wire into entrypoint.sh

In `entrypoint.sh`, the settings.json generation step:

```bash
jq '.hooks = {"AfterTool": "/usr/local/bin/claude-hook-aftertool"}' \
  /home/dev/.claude-host-settings.json > /tmp/host-settings.json
mv /tmp/host-settings.json /home/dev/.claude-host-settings.json
```

### Step 4: Verify

```bash
# Make some Claude tool calls, then:
clickhouse-client --host host.orb.internal \
  --query "SELECT event_name, count(), avg(duration_ms) FROM kyb.claude_event_log GROUP BY event_name"
```
