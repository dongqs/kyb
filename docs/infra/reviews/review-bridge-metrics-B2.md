---
decision: 稍后做
---

# Review B2: bridge-metrics-logging.md

**Reviewer:** B2
**File:** `docs/infra/designs/bridge-metrics-logging.md`
**Status:** Needs revision

## Finding: turn_duration / tokens format mismatch

### Problem

The spec declares `turn_duration_seconds` and `tokens_per_turn` as histograms but annotates them with semantics that belong to different metric types:

| Metric | Declared type | Annotated with | Problem |
|--------|--------------|----------------|---------|
| `turn_duration_seconds` | histogram | P50/P90/P99 | Percentiles are a Summary concept, not a native histogram property |
| `tokens_per_turn` | histogram | input/output | Unclear whether these are separate metrics or labels on one metric |

### Detail

**`turn_duration_seconds` (histogram)**
- Histograms expose `_bucket`, `_count`, `_sum` time series. To compute P50/P90/P99 you must use `histogram_quantile()` in PromQL — the percentiles are not emitted by the instrumented code.
- If the intent is to have the instrumentation library emit pre-computed quantiles server-side, the correct type is a `Summary`, not a `Histogram`.
- If the intent truly is a histogram, the spec should document the bucket boundaries (e.g., exponential or custom buckets from 50ms to 300s) so that consumers know what resolution to expect in the quantile approximations.

**`tokens_per_turn` (histogram, input/output)**
- "input/output" is ambiguous: are these two separate histogram metrics (`tokens_input_per_turn`, `tokens_output_per_turn`), or a single histogram with an `io` label (`io="input"` / `io="output"`)?
- If separate metrics, write them as separate lines.
- If a label dimension, say so explicitly: `tokens_per_turn (histogram, dimensions: io in [input, output])`.

### Recommendation

Replace the metrics table with an unambiguous declaration:

```yaml
metrics:
  - name: turn_duration_seconds
    type: histogram
    description: End-to-end turn latency
    buckets: [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300]
    p50/p90/p99: computed via histogram_quantile() in PromQL

  - name: tokens_per_turn
    type: histogram
    description: Tokens consumed per turn, by direction
    dimensions:
      - name: direction
        values: [input, output]
    buckets: [1, 50, 100, 500, 1000, 2000, 4000, 8000, 16000]
```

This eliminates the type/annotation mismatch and makes the schema unambiguous for implementers.
