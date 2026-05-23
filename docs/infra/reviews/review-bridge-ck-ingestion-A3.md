---
decision: 稍后做
---

# Review A3: bridge-ck-ingestion.md — Grafana Panel Feasibility

Review of `docs/infra/designs/bridge-ck-ingestion.md`.

## Summary

A sound design for a low-volume message log pipeline (Vector -> ClickHouse -> Grafana). The schema is well-chosen for the data shape, and the resource estimates are conservative. The five proposed Grafana panels are all feasible, but two need significant clarification before implementation.

## Grafana Panel Feasibility

### 1. Message Overview (Time Series) -- Feasible, no changes needed

Simple `GROUP BY event_type` / `count()` with `$__interval` macro. ClickHouse data source handles this natively. The 1-minute granularity is appropriate for the expected volume (~90 msgs/day).

### 2. Response Latency Heatmap (Heatmap) -- Feasible, but design is unclear

The description mixes two distinct visualization patterns:

**Heatmap side (feasible):** A Grafana heatmap displays a 2D histogram: X = time, Y = bucket, cell color = count. With ClickHouse data source, the recommended approach is:

```sql
SELECT
  $__timeGroup(event_time, '$__interval') AS time,
  multiIf(
    turn_duration <= 1,   '0-1s',
    turn_duration <= 5,   '1-5s',
    turn_duration <= 15,  '5-15s',
    turn_duration <= 30,  '15-30s',
    turn_duration <= 60,  '30-60s',
                         '>60s'
  ) AS bucket,
  count() AS count
FROM cc.message_log
WHERE event_type = 'message_sent'
  AND $__timeFilter
GROUP BY time, bucket
```

This produces a valid heatmap. The fix is in the doc: the bucket labels ("0-1s", "1-5s" etc.) must be a single categorical column, not a set of separate columns. The current wording ("分桶（0-1s, 1-5s, 5-15s, 15-30s, 30-60s, >60s）") is ambiguous.

**P50/P90/P99 overlay (separate concern):** Percentile time series cannot be superimposed on a heatmap -- they belong on a companion Time Series panel. The doc should split these into two panels:
- Panel 2a: Heatmap (distribution density over time)
- Panel 2b: Latency percentile line chart (P50, P90, P99)

Alternatively, keep the percentile query from the doc's example and render it as a Time Series panel. The heatmap adds little value at this volume (~90 msgs/day, so many time buckets will have too few points for a meaningful heatmap). **Recommendation:** drop the heatmap entirely and keep only the percentile Time Series panel. Revisit heatmap if volume grows >1000 msgs/day.

### 3. User Activity Top-N (Bar Chart / Table) -- Feasible, no changes needed

Standard `GROUP BY sender_id ORDER BY count() DESC LIMIT 20`. ClickHouse handles this instantly even on full 90-day dataset (~27K rows max). The doc correctly specifies this.

### 4. Token Consumption Stacked Area (Stacked Area) -- Feasible, needs small fix

The query must use `toStartOfHour(event_time)` for the 1-hour aggregation and `sum(input_tokens)` / `sum(output_tokens)`. The doc should note that `input_tokens` and `output_tokens` are populated only for `message_sent` events (as stated in the schema), so the WHERE clause must filter `event_type = 'message_sent'`. The current doc does not show a SQL example for this panel -- it should, to avoid confusion.

### 5. Recent Messages Table (Table) -- Feasible, no changes needed

Simple `ORDER BY event_time DESC LIMIT 50`. The doc correctly notes `content_text` should be truncated in the Grafana column display settings (use "Trim" or "Ellipsis" in field overrides).

## Other Review Findings

### Log ingestion reliability (medium concern)

Vector's Docker log source (`docker_logs`) maintains a cursor file for checkpointing. The doc says "docker logs or directly mount log files" -- these are different mechanisms with different reliability:

- `docker_logs` source: Vector tracks cursor position across restarts (no data loss)
- File tailing: relies on log rotation policy; can miss lines on rotation

The doc should standardise on the `docker_logs` source (a built-in Vector component) and include an example `vector.toml` snippet.

### Missing Vector config example

The design describes the pipeline but provides no `vector.toml` configuration. This is the most likely source of implementation friction. A minimal example would cover:

```toml
[sources.cc_connect]
type = "docker_logs"
containers = ["cc-connect"]
auto_partial_merge = true

[transforms.parse_json]
type = "remap"
inputs = ["cc_connect"]
source = '''
. = parse_json!(.message) ?? {}
'''

[sinks.clickhouse]
type = "clickhouse"
inputs = ["parse_json"]
endpoint = "http://clickhouse:8123"
database = "cc"
table = "message_log"
batch.max_bytes = 1048576
batch.timeout_secs = 10
```

### Table schema suggestions

| Field | Issue | Suggestion |
|-------|-------|------------|
| `content_text` String | No codec specified | Add `CODEC(ZSTD(3))` -- text compresses well |
| `trace_id` String | In ORDER BY so it's indexed, but high cardinality | Acceptable at this volume; no change needed |
| `chat_id` String | Used in WHERE for user queries | Consider adding `INDEX idx_chat_id chat_id TYPE set(100) GRANULARITY 4` if volume grows |
| All numeric fields | No codec specified | ClickHouse default codecs are adequate at this scale |

### Operational gaps

- **No Vector health monitoring**: If Vector dies, data loss is silent. Add a paragraph about monitoring Vector (Grafana Agent or Prometheus scraping Vector's `/metrics` endpoint, plus a blackbox probe).
- **No schema migration plan**: The doc should mention how to add/drop columns without downtime (ClickHouse `ALTER TABLE` is online, but downstream Grafana queries must be updated).
- **No mention of authentication**: ClickHouse HTTP endpoint should not be open to the network. Vector should authenticate via password or network ACL.
- **No sampling/retention tiers**: At 90 msgs/day, raw data retention at 90 days is fine. This assumption should be documented explicitly so it's not silently relied upon at higher volume.

## Verdict

**Conditionally approve.** The five Grafana panels are feasible with minor corrections (clarify heatmap vs. percentile split, add SQL example for token consumption panel). The design should add a `vector.toml` config snippet and address the three operational gaps (Vector health, schema migration, auth) before implementation begins.
