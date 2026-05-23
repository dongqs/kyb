# ClickHouse 容器化部署手册

## 容器信息

| 字段 | 值 |
|------|-----|
| 容器名 | kyb-infra-clickhouse |
| 镜像 | clickhouse/clickhouse-server:24.2-alpine |
| 端口 | 8123 (HTTP), 9000 (native TCP) |
| 网络 | kyb-net |

## Docker Run

```bash
docker volume create ch-data
docker run -d --name kyb-infra-clickhouse \
  --network kyb-net --restart unless-stopped \
  -p 8123:8123 -p 9000:9000 \
  -v ch-data:/var/lib/clickhouse \
  clickhouse/clickhouse-server:24.2-alpine
```

## 验证

```bash
curl http://host.orb.internal:8123/?query=SELECT+1
# → 1
```

## Kafka Engine 表

```sql
CREATE TABLE kafka_ingest.infra_metrics_queue (
  timestamp DateTime64(3), host String, container_name String,
  metric_name String, metric_value Float64, tags Map(String,String)
) ENGINE = Kafka
SETTINGS kafka_broker_list = 'kyb-infra-kafka:9092',
         kafka_topic_list = 'infra-metrics',
         kafka_group_name = 'ck-consumer-1',
         kafka_format = 'JSONEachRow';
```

## 踩坑

| 现象 | 原因 | 修复 |
|------|------|------|
| Grafana 面板空白 | CK v4 插件需 `jsonData.server` | provisioning 里加 `jsonData: { server: host.orb.internal, port: 8123 }` |
| `format: "time_series"` 报错 | CK v4 插件不接受下划线 | 改为 `"timeseries"`（无下划线） |
| TTL 不生效 | `DateTime64(3)` 不能直接 TTL | 用 `TTL toDate(timestamp) + INTERVAL 30 DAY` |
| CK 查询走代理巨慢 | `NO_PROXY` 没设 | `NO_PROXY=host.orb.internal,kyb-infra-*,localhost` |
| 宿主机 CK 端口冲突 | 宿主机已有 CK 进程 | 停宿主 CK 或改容器端口映射 |
