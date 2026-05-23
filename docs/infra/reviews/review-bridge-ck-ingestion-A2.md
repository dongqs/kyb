---
decision: 稍后做
---

# Review A2: bridge-ck-ingestion.md

- **Reviewer**: boss
- **Date**: 2026-05-23
- **Document**: `docs/infra/designs/bridge-ck-ingestion.md`
- **Status**: **Design is sound; execution gaps identified.**

---

## 1. Summary

The design doc proposes a clean, minimal pipeline: cc-connect stdout -> Vector -> ClickHouse -> Grafana. The data volume is tiny (~3 MB / 90 days), so no scaling concerns. The schema is well-chosen with LowCardinality on low-cardinality fields and a sensible sort key `(event_time, trace_id)`. Overall the doc is production-ready from a design standpoint.

---

## 2. Vector / CK Status

### 2.1 ClickHouse

| Component | Status |
|-----------|--------|
| ClickHouse server | **Running** (`kyb-infra-clickhouse`, `clickhouse/clickhouse-server:24.2-alpine`) |
| `cc` database | **Not created** |
| `cc.message_log` table | **Not created** — the `CREATE TABLE` from the doc has never been run |
| Grafana | **Running** (`kyb-infra-grafana`), could add a CK datasource and panels immediately |

ClickHouse is alive and well with ~55 databases already in use. The bottleneck is purely DDL execution and Vector deployment — CK is ready to receive data once the pipeline exists.

### 2.2 Vector

| Component | Status |
|-----------|--------|
| Vector binary | **Not installed** on any host |
| Vector container | **Not running** — no `kyb-infra-vector` or similar container exists |
| Vector config | **Not created** — no config file or volume mount prepared |
| Vector sink | **Not tested** — the CK table it writes to does not exist yet |

Vector is the largest gap. The doc says "Vector runs as a standalone container, co-located with cc-connect on the same machine." This needs:
1. A Vector container (official `timberio/vector` image)
2. A config file mounted in with a `docker_logs` source targeting cc-connect and a `clickhouse` sink targeting `host.orb.internal:8123`
3. The `cc` database and `cc.message_log` table created in CK first (otherwise Vector's sink health check will fail at startup)

### 2.3 cc-connect (Source)

| Component | Status |
|-----------|--------|
| cc-connect container | **Running** (`kyb-infra-cc-connect`) |
| Structured JSON logs | **Confirmed** — logs contain all fields from the schema: `msg_id`, `session`, `user`, `content_len`, `has_images`, `tools`, `response_len`, `turn_duration`, `input_tokens`, `output_tokens` |
| Log format drift | **Minor** — field names in real logs use underscores (e.g. `content_len`, `turn_duration`) which match the CK column names. `has_audio`, `has_files` exist in logs but are not in the schema. |

The source is healthy and producing the expected data. The schema fields align with the actual log output.

---

## 3. Schema Review

| Aspect | Verdict |
|--------|---------|
| Column types | **Correct** — LowCardinality on the right fields, DateTime64(3) for millisecond precision, UIntNN for counters |
| Sort key `(event_time, trace_id)` | **Correct** — covers the two main query patterns (time range + trace lookup) |
| TTL 90 days | **Correct** — aligns with operational needs; no manual cleanup needed |
| Missing columns | **Minor** — `has_audio`, `has_files` exist in source logs but are not captured. Not blocking, but worth adding for completeness if anyone needs to filter audio/file messages. |

The TTL-only retention (no partitioning) is correct for this data volume. A single MergeTree table is sufficient.

---

## 4. Deployment Gaps

The following must be done before this pipeline is operational:

1. **Create `cc` database and `cc.message_log` table** in ClickHouse (execute the `CREATE TABLE` from the doc).
2. **Deploy Vector container** (docker run with `timberio/vector:latest-alpine`, bind-mount config).
3. **Write Vector config** (TOML) with:
   - `docker_logs` source filtering to cc-connect container
   - `remap` transform to parse JSON fields and handle type coercion
   - `clickhouse` sink targeting `http://host.orb.internal:8123` with `cc.message_log` table
4. **Configure Grafana datasource** (CK HTTP endpoint on `host.orb.internal:8123`).
5. **Create Grafana dashboards** (the 5 panels described in the doc).
6. **Verify end-to-end**: send a test message, confirm it arrives in CK within Vector's flush interval.

---

## 5. Recommendations

- **Low priority**: add `has_audio` (UInt8) and `has_files` (UInt8) columns to the schema since cc-connect already emits them — zero cost, future-proofs the schema.
- **Low priority**: add `reaction_type` or event-type awareness — cc-connect now logs reaction events (`im.message.reaction.deleted_v1`). These are not message events per the current schema, but worth noting for a future iteration.
- **No changes needed** to the core design. It is minimal, correct, and appropriate for the data volume.

---

## 6. Conclusion

The design is solid. The execution gap is entirely in deployment: Vector is not running, the CK table is not created, and Grafana dashboards have not been built. These are straightforward tasks, not architectural problems. Estimated effort: < 1 hour for one person.

**Ship the design, dispatch the deployment.**
