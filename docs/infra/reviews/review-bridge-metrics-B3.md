---
decision: 稍后做
---

# Review B3: Bridge Metrics & Logging -- Grafana Panel Reusability

Reviewed: `docs/infra/designs/bridge-metrics-logging.md`

## Summary

The design doc defines the metrics and logging surface for the bridge (Feishu -> cc-connect -> Claude -> response -> Feishu) but stops at listing three Grafana panel categories (延迟趋势图, 错误率, 吞吐量). There is no discussion of how these panels will be built, shared, or maintained. This review covers Grafana panel reusability specifically.

## Findings

### 1. No panel taxonomy or naming convention

The doc lists "延迟趋势图、错误率、吞吐量" as one-liners. There is no naming convention, no folder structure, and no taxonomy (e.g., time-series vs. stat vs. table) defined. Without this, every panel becomes a bespoke creation -- hard to find, hard to reuse.

**Recommendation:** Define a panel naming convention early, e.g.:
```
Bridge / Latency / Turn Duration P99
Bridge / Errors / by Error Type
Bridge / Throughput / Messages per Minute
```

### 2. No dashboard-as-code strategy

No mention of how dashboards are provisioned. If panels are built by hand in the Grafana UI, they cannot be version-controlled, reviewed, or reused across environments (staging vs. production, or different bridge instances).

**Recommendation:** Adopt a dashboard-as-code approach (Terraform `grafana_dashboard` resource, or Jsonnet/grafonnet, or at minimum a JSON commit-and-review workflow in a `dashboards/` directory). Library panels should be created as Grafana library panels so they can be referenced across dashboards.

### 3. No shared query templates

The metrics defined (histograms, counters, gauges) are standard Prometheus patterns, but the doc does not provide PromQL snippets or reusable query templates. For example, a "P99 latency" panel for `turn_duration_seconds` should be a reusable component that can also be applied to other histogram metrics (`tokens_per_turn`).

**Recommendation:** Define a small set of reusable query macros or templates:
- `histogram_pXX(metric, le)` for all histogram panels
- `error_rate(errors_total, messages_received_total)` for error ratio panels
- These can be baked into Grafana library panels or at minimum documented as PromQL snippets.

### 4. No cross-service panel reuse plan

The bridge metrics follow the same pattern as other services (counter, histogram, gauge). Any panel built for the bridge's latency or error rate could be reused by other services (cc-connect internal, MCP gateway, etc.) if dimensions and labels are consistent.

**Recommendation:** Standardize on label conventions across all bridge-related services so that panels like "Error rate by service" can be built once and reused. Specifically:
- Ensure `service="bridge"` label is present on all metrics
- Ensure `error_type` dimension values are consistent with other services
- Consider building a "Service Overview" library panel that works for any service label.

### 5. Missing panel-level metadata

The doc doesn't describe panel-level metadata (descriptions, units, thresholds) that would enable reuse. Without descriptions, a panel's intent is unclear to new consumers.

**Recommendation:** For each panel type, specify:
- Unit (ms for latency, ops/s for throughput, ratio for error rate)
- Target SLO thresholds (e.g., P99 < 5s, error rate < 1%)
- Minimum viable time range for meaningful display
- These should be part of the library panel definition, not just documentation.

### 6. No panel composition strategy

The three panel types are listed flat; there is no hierarchy or drill-down pattern. A reusable dashboard design typically uses:
- Top-level summary row (stat panels: current error rate, active sessions)
- Middle detail row (time series: latency trends, throughput)
- Bottom diagnostic row (per-dimension breakdowns)

**Recommendation:** Define a row-level layout that can be reused across service dashboards. The bridge dashboard should follow the same skeleton as other service dashboards.

## Conclusion

The design doc provides a solid metrics foundation but completely omits the Grafana implementation strategy. Without addressing panel reusability, the three Grafana items will likely be built as one-off panels, leading to maintenance burden as the bridge system grows. The recommendations above are low-effort, high-leverage: naming conventions, dashboard-as-code, and library panels cost very little upfront but prevent panel proliferation.

**Severity:** Medium. Not blocking but will compound if deferred past the first dashboard implementation.
