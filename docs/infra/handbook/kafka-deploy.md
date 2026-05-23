# Kafka KRaft 部署手册

## 容器信息

| 字段 | 值 |
|------|-----|
| 容器名 | kyb-infra-kafka |
| 镜像 | apache/kafka:latest |
| 端口 | 9092 (PLAINTEXT), 9093 (controller) |
| 网络 | kyb-net |

## Docker Run

```bash
docker volume create kafka-data
docker run -d --name kyb-infra-kafka \
  --network kyb-net --restart unless-stopped \
  -p 9092:9092 \
  -v kafka-data:/var/lib/kafka/data \
  -e KAFKA_NODE_ID=1 \
  -e KAFKA_PROCESS_ROLES=broker,controller \
  -e KAFKA_CONTROLLER_QUORUM_VOTERS="1@kyb-infra-kafka:9093" \
  -e KAFKA_LISTENERS="PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093" \
  -e KAFKA_ADVERTISED_LISTENERS="PLAINTEXT://kyb-infra-kafka:9092" \
  -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP="PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT" \
  -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
  -e KAFKA_LOG_DIRS=/var/lib/kafka/data \
  -e KAFKA_AUTO_CREATE_TOPICS_ENABLE=true \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
  -e KAFKA_HEAP_OPTS="-Xmx512m -Xms512m" \
  apache/kafka:latest
```

## 验证

```bash
docker exec kyb-infra-kafka kafka-topics.sh --bootstrap-server localhost:9092 --list
```

## 踩坑

| 现象 | 原因 | 修复 |
|------|------|------|
| Kafka 吃掉 4GB RAM | 默认 JVM heap 太大 | 必须设 `KAFKA_HEAP_OPTS="-Xmx512m -Xms512m"` |
| Kafka 起不来 | KRaft 目录未格式化 | 删 volume 重来: `docker rm -f kyb-infra-kafka && docker volume rm kafka-data` |
| 从宿主机连不上 | `ADVERTISED_LISTENERS` 设了容器名 | 宿主机用 `localhost:9092`，容器内用 `kyb-infra-kafka:9092` |
| 磁盘暴增 | 默认 retention 无限 | `KAFKA_LOG_RETENTION_HOURS=168` 或设 `KAFKA_LOG_RETENTION_BYTES` |
