---
decision: 稍后做
---

# Review A1: bridge-ck-ingestion design

**Design doc**: `docs/infra/designs/bridge-ck-ingestion.md`
**Reviewer**: A1
**Date**: 2026-05-23
**Scope**: Field mapping correctness, log format assumptions, data model completeness

---

## Summary

The design is a well-structured proposal for persisting cc-connect message data into ClickHouse via Vector. However, it contains a fundamental mismatch: the actual cc-connect log output is **not JSON** and its field set differs significantly from what the design assumes. Several required fields are missing from the source logs, and the `msg_id` join key across log lines is underspecified.

---

## Critical finding: cc-connect log format vs design

### Design assumption

> cc-connect 以 JSON 格式输出结构化日志到 stdout（每行一条消息记录）

### Actual format

cc-connect outputs two distinct log formats on stdout:

1. **Structured log lines** (info/warn level, Go `log/slog` key=value format, **not JSON**):
   ```
   time=2026-05-23T16:38:00.604Z level=INFO msg="turn complete" session=s1 agent_session=d2720c67-... msg_id=om_x... tools=2 response_len=554 turn_duration=4h13m27.227059634s input_tokens=431 output_tokens=521
   time=2026-05-23T16:37:37.828Z level=INFO msg="message received" platform=feishu msg_id=om_x... session=feishu:oc_...:ou_... user=ou_... content_len=65 has_images=false has_audio=false has_files=false
   time=2026-05-23T16:39:03.343Z level=INFO msg="permission request" request_id=... tool=Bash
   time=2026-05-23T16:37:55.717Z level=INFO msg="permission resolved" request_id=...
   time=2026-05-23T16:38:01.190Z level=WARN msg="slow agent send" elapsed=... session=... content_len=...
   ```

2. **Debug log lines** (Go standard `[Debug]` timestamped prefixes, unstructured):
   ```
   2026/05/23 16:37:37 [Debug] [[receive message, message_type: event, message_id: ..., trace_id: ..., payload: {...}]]
   ```

Vector cannot use a JSON parser on these lines. The key=value format requires a regex or key-value parser transform.

### Field-by-field comparison

| Design field | In actual logs? | Status |
|---|---|---|
| `event_time` | Yes, as `time=` in key=value format (ISO-8601 with ms) | OK, needs parser |
| `event_type` | Not as a field. Derivable from `msg`: `"message received"` / `"turn complete"` | Needs transform |
| `trace_id` | Only in Debug lines, not in structured INFO lines | **Missing from INFO logs** |
| `message_id` | Yes, as `msg_id=om_x...` in both receive and turn complete | OK |
| `chat_id` | Embedded in `session=feishu:oc_...:ou_...` as 2nd colon-delimited segment | Needs extraction |
| `chat_type` | Not logged | **Missing** |
| `sender_id` | Yes, as `user=ou_...` in "message received" only. Not in "turn complete" | Partially missing |
| `sender_type` | Not logged | **Missing** |
| `message_type` | Not logged (could be derived from content structure, but not directly) | **Missing** |
| `content_text` | Not logged. Only `content_len` is recorded (raw msg length, not text length) | **Missing** |
| `content_len` | Yes | OK |
| `has_images` | Yes (also has `has_audio`, `has_files`) | OK, extra fields available |
| `session` | Yes, as `session=` | OK |
| `agent_session` | Yes, in "turn complete" only | OK for outbound |
| `response_len` | Yes, in "turn complete" only | OK |
| `turn_duration` | Yes, but as Go duration string (`4h13m27.227059634s`), not Float64 seconds | Needs parsing |
| `input_tokens` | Yes, in "turn complete" only | OK |
| `output_tokens` | Yes, in "turn complete" only | OK |
| `tools_used` | Yes, as `tools=2` ("tools" not "tools_used") | Minor naming mismatch |

### Consolidated record requires a join

The design implicitly assumes each message produces a single log line with all fields. In reality, one message turn produces **at least two** separate log lines:

1. `msg="message received"` -- has: time, msg_id, user, session, content_len, has_images/has_audio/has_files
2. `msg="turn complete"` -- has: time, msg_id, session, agent_session, tools, response_len, turn_duration, input_tokens, output_tokens

These must be **joined on `msg_id`** to produce a complete record. The join logic belongs in the Vector transform pipeline.

### `turn_duration` format mismatch

The design specifies `Float64` (seconds). The actual log value is a Go `time.Duration` string: `4h13m27.227059634s`, `2.941035153s`, etc. Vector needs a transform to parse this into fractional seconds before inserting into ClickHouse.

---

## Other findings

### chat_id extraction

The `session` field in "message received" lines is formatted as `feishu:oc_<chat_id>:ou_<user_id>`. The `chat_id` can be extracted as the second segment, but this is fragile and undocumented.

### No Vector config in scope

The design mentions Vector as the collector but does not include a Vector configuration (`.toml`). The parsing transforms described above (key=value parsing, duration conversion, msg_id-based join) should be prototyped in a Vector config to validate the pipeline.

### Storage overestimation

Daily message volume (~90 messages/day) and storage (~3 MB / 90 days) are **correctly** estimated as negligible. ClickHouse will have no trouble with this scale. A MergeTree with 90-day TTL and no partitioning is appropriate.

### Grafana panels look reasonable

The five proposed panels (message overview, response latency heatmap, user activity top-N, token consumption stacked area, recent messages table) map well to the available fields. The "turn_duration" panel will need the duration-to-seconds transform in place.

### `has_audio` and `has_files` fields

The actual logs include `has_audio` and `has_files` booleans that are not in the design schema. Consider adding these to the ClickHouse table as they cost almost nothing (UInt8, columnar) and may be useful for future analysis.

---

## Recommendations

1. **P0 -- Correct the log format assumption**: The design must explicitly document that cc-connect outputs Go `slog` key=value format, not JSON. The Vector source config should use a `regex_parser` or custom transform instead of `json_parser`.

2. **P0 -- Add msg_id-based join transform**: The Vector pipeline must join "message received" and "turn complete" events on `msg_id` to produce consolidated records.

3. **P1 -- Add turn_duration parsing**: Vector must convert Go duration strings to Float64 seconds before inserting.

4. **P1 -- Mark missing fields**: Add a note to the field table about which fields are not directly available from cc-connect logs (`chat_type`, `sender_type`, `message_type`, `content_text`, `trace_id`). These require either cc-connect code changes or acceptance of null.

5. **P2 -- Consider adding `has_audio` and `has_files`** to the ClickHouse schema for future use.

6. **P2 -- Include a Vector config prototype** in the design to validate the full pipeline.

---

## Verdict

**Conditionally approve** -- the overall architecture (Vector + ClickHouse + Grafana) is sound and the storage estimates are accurate. However, the critical log format assumption must be corrected and the join transform must be added before implementation. Without these, Vector will fail to parse any input.
